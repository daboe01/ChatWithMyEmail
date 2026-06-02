#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use DBI;
use Mojo::UserAgent;
use Mojo::JSON qw(encode_json decode_json);
use Digest::MD5 qw(md5_hex);
use POSIX qw(strftime);
use IPC::Open2;

# Ensure standard output uses UTF-8 encoding
binmode(STDOUT, ":utf8");

# ==========================================
# CONFIGURATION
# ==========================================
my $MAILBOX       = 'NOTES';
my $FOLDER_FILTER = ''; 

my $DB_DSN        = 'dbi:Pg:dbname=my_email;host=localhost';
my $DB_USER       = 'postgres';
my $DB_PASS       = 'postgres';

my $OLLAMA_URL    = 'http://localhost:11434/api/embeddings';
my $EMBED_MODEL   = 'mxbai-embed-large'; # 1024 dimensions

# ==========================================
# INITIALIZE CONNECTIONS
# ==========================================
my $ua = Mojo::UserAgent->new;
$ua->inactivity_timeout(30);

my $dbh = DBI->connect($DB_DSN, $DB_USER, $DB_PASS, {
                       RaiseError        => 1,
                       AutoCommit        => 1,
                       pg_enable_utf8    => 1,
}) or die "Could not connect to database: $DBI::errstr";

my $sth_insert_email = $dbh->prepare(q{
                                     INSERT INTO emails (imap_uid, mailbox, message_id, subject, sender, recipient, date_sent, is_unread, body_text, body_html, raw_mime)
                                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                                     ON CONFLICT (message_id) DO UPDATE
                                     SET imap_uid  = EXCLUDED.imap_uid, 
                                         mailbox   = EXCLUDED.mailbox,
                                         subject   = EXCLUDED.subject,
                                         body_text = EXCLUDED.body_text,
                                         date_sent = EXCLUDED.date_sent
                                     RETURNING id
});

my $sth_insert_embed = $dbh->prepare(q{
                                     INSERT INTO email_embeddings (idemail, embedding)
                                     VALUES (?, ?::vector)
                                     ON CONFLICT (idemail) DO UPDATE SET embedding = EXCLUDED.embedding
});

# ==========================================
# FETCH AND PARSE APPLE NOTES
# ==========================================
print "\n=========================================\n";
print "Starting sync for Apple Notes folder: [$MAILBOX]\n";
print "=========================================\n";

my $cmd = "memo notes";
if ($FOLDER_FILTER ne '') {
    $cmd .= " -f " . quotemeta($FOLDER_FILTER);
}

my @list_output = `$cmd`;
if ($? != 0) {
    die "Error: Failed to execute '$cmd'. Ensure 'memo' is installed and authorized to access Apple Notes.\n";
}

my $synced_count = 0;

foreach my $line (@list_output) {
    $line =~ s/\e\[[0-9;]*[a-zA-Z]//g; # Clean terminal colors

    if ($line =~ /^\s*(?:\[([^\]]+)\]\s+)?(\d+)\s*[:.]\s*(.+)$/) {
        my $folder = $1 // 'Notes';
        my $index  = $2;
        my $title  = $3;
        $title =~ s/^\s+|\s+$//g;

        print "Processing Note Index $index: [$title]... ";

        my $content = `memo notes -v $index`;
        if ($? != 0 || !defined $content || $content eq '') {
            print "Failed to fetch content. Skipping.\n";
            next;
        }
        
        $content =~ s/\e\[[0-9;]*[a-zA-Z]//g;

        # Extract subject from first line / paragraph
        my $subject = '(No Title)';
        if ($content =~ /\A\s*(.+?)\s*(?:\n|$)/) {
            $subject = $1;
        }
        $subject =~ s/^#+\s*//;
        $subject =~ s/\s+$//;

        # Clean RTF/HTML/Markdown structure and binary chunks
        my $cleaned_body = clean_note_body($content);
        my $current_time = strftime("%Y-%m-%d %H:%M:%S", localtime);
        my $message_id   = "apple-note-" . md5_hex($subject) . "\@local";

        # Build clean structural context block for vector embedding
        my $text_to_embed = sprintf(
            "Email Folder: %s\n" .
            "From: %s\n" .
            "To: %s\n" .
            "Date: %s\n" .
            "Subject: %s\n\n" .
            "Content:\n%s",
            $MAILBOX,
            'Apple Notes (' . $folder . ')',
            $ENV{USER} // 'Local User',
            $current_time,
            $subject,
            substr($cleaned_body, 0, 1200)
        );

        my $embedding_vector = get_embedding($text_to_embed);
        my $success = 0;
        my $inserted_id;

        eval {
            $dbh->begin_work;

            $sth_insert_email->execute(
                $index,
                $MAILBOX,
                $message_id,
                $subject,
                'Apple Notes',
                $ENV{USER} // 'Local User',
                $current_time,
                0,
                $cleaned_body,             # Store the fully sanitized plain text body
                undef,                     # body_html
                undef                      # raw_mime
            );
            ($inserted_id) = $sth_insert_email->fetchrow_array();
            $dbh->commit;
            $success = 1;
        };

        if ($@) {
            warn "Database insert error for Note Index $index: $@\n";
            $dbh->rollback;
        }

        if ($success && $inserted_id) {
            if ($embedding_vector) {
                eval {
                    $dbh->begin_work;
                    $sth_insert_embed->execute($inserted_id, $embedding_vector);
                    $dbh->commit;
                };
                if ($@) {
                    warn "Embedding insertion failed for Local ID $inserted_id: $@\n";
                    $dbh->rollback;
                }
            }
            print "Synced successfully as Local ID: $inserted_id\n";
            $synced_count++;
        }
    }
}

$dbh->disconnect();
print "\n$synced_count Apple Notes synchronized.\n";


# ==========================================
# SUBROUTINES / HELPERS
# ==========================================

sub clean_note_body {
    my ($body) = @_;
    return "" unless defined $body;

    # 1. Strip memo's custom image placeholder tokens
    $body =~ s/\[MEMO_IMG_\d+\]//g;

    # 2. Strip binary blocks (unbroken Base64 / raw hex lists common in embeds)
    $body =~ s/\b[A-Za-z0-9\+\/=]{80,}\b//g;
    $body =~ s/\b[a-fA-F0-9]{80,}\b//g;

    # 3. Use Pandoc to cleanly parse away RTF control codes or styling artifacts
    $body = clean_with_pandoc($body);

    # 4. Standard spacing cleanups
    $body =~ s/[ \t]+/ /g;
    $body =~ s/\r//g;
    $body =~ s/\n{3,}/\n\n/g;
    $body =~ s/^\s+|\s+$//g;

    return $body;
}

sub clean_with_pandoc {
    my ($content) = @_;
    return "" unless defined $content && $content ne '';

    # Identify source markup format
    my $from_format = 'markdown';
    if ($content =~ /^\s*\{\\rtf/s) {
        $from_format = 'rtf';
    } elsif ($content =~ /^\s*<html/si || $content =~ /^\s*<!DOCTYPE/si) {
        $from_format = 'html';
    }

    # Use bidirectional pipes via IPC::Open2
    my ($ch_out, $ch_in);
    my $pid;
    
    eval {
        $pid = open2($ch_out, $ch_in, 'pandoc', '-f', $from_format, '-t', 'plain', '--wrap=none');
    };
    if ($@) {
        warn "Pandoc is not accessible or not installed. Falling back to simple regex cleanup.\n";
        return clean_fallback_regex($content);
    }

    # Send note content to Pandoc input buffer
    binmode($ch_in, ":utf8");
    print $ch_in $content;
    close $ch_in;

    # Collect rendered plain text from Pandoc output buffer
    binmode($ch_out, ":utf8");
    my $cleaned = do { local $/; <$ch_out> };
    close $ch_out;

    waitpid($pid, 0);

    # Fall back if Pandoc encountered an execution error or empty buffer
    if ($? != 0 || !defined $cleaned || $cleaned eq '') {
        return clean_fallback_regex($content);
    }

    return $cleaned;
}

sub clean_fallback_regex {
    my ($body) = @_;
    
    # Strip basic HTML tags
    $body =~ s/<[^>]+>//g;

    # Standard RTF code control keyword fallback strip
    if ($body =~ /^\s*\{\\rtf/) {
        $body =~ s/\\'[a-f0-9]{2}//g;
        $body =~ s/\{[^}]*\}//g;
        $body =~ s/\\[a-z0-9*-]+//g;
    }

    return $body;
}

sub get_embedding {
    my ($text) = @_;
    my $payload = {
        model  => $EMBED_MODEL,
        prompt => $text,
    };

    my $tx = $ua->post($OLLAMA_URL => json => $payload);
    if ($tx->result && $tx->result->is_success) {
        my $res = decode_json($tx->result->body);
        my $vector = $res->{embedding};
        return '[' . join(',', @$vector) . ']';
    } else {
        warn "Ollama embedding generation failed: " . ($tx->error ? $tx->error->{message} : "Unknown error");
        return undef;
    }
}
