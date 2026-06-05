#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use DBI;
use Mojo::UserAgent;
use Mojo::JSON qw(encode_json decode_json);
use Digest::MD5 qw(md5_hex);
use POSIX qw(strftime);
use File::Temp qw(tempfile);
use Encode qw(decode_utf8 encode_utf8);
use File::Find; # Added for recursive directory traversal
use File::Spec; # Added for cross-platform path handling

# Ensure standard output uses UTF-8 encoding
binmode(STDOUT, ":utf8");

# ==========================================
# CONFIGURATION
# ==========================================
# Choose import mode: 'APPLE_NOTES' or 'MARKDOWN_FOLDER'
my $IMPORT_MODE   = 'APPLE_NOTES';

# -- Options for 'APPLE_NOTES' Mode
my $MAILBOX       = 'NOTES';
my $FOLDER_FILTER = '';

# -- Options for 'MARKDOWN_FOLDER' Mode (e.g., from "Exporter" app)
my $MD_FOLDER     = '/path/to/exported/notes';

# -- DB & Embedding Configuration
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

# Insert query utilizing message_id (content hash) as a unique constraint to avoid duplicates
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
# GATHER NOTES (APPLE NOTES OR MARKDOWN FILES)
# ==========================================
my @notes_to_sync;

if ($IMPORT_MODE eq 'APPLE_NOTES') {
    print "\n=========================================\n";
    print "Starting sync for Apple Notes folder: [$MAILBOX]\n";
    print "=========================================\n";

    my $cmd = "memo notes";
    if ($FOLDER_FILTER ne '') {
        $cmd .= " -f " . quotemeta($FOLDER_FILTER);
    }

    # Capture command output as raw bytes
    my @list_output_bytes = `$cmd`;
    if ($? != 0) {
        die "Error: Failed to execute '$cmd'. Ensure 'memo' is installed and authorized to access Apple Notes.\n";
    }

    # Explicitly decode raw terminal bytes to Perl character strings
    my @list_output = map { decode_utf8($_) } @list_output_bytes;

    foreach my $line (@list_output) {
        $line =~ s/\e\[[0-9;]*[a-zA-Z]//g; # Clean terminal colors

        if ($line =~ /^\s*(?:\[([^\]]+)\]\s+)?(\d+)\s*[:.]\s*(.+)$/) {
            my $folder = $1 // 'Notes';
            my $index  = $2;
            my $title  = $3;
            $title =~ s/^\s+|\s+$//g;

            # Capture raw bytes of note contents
            my $content_bytes = `memo notes -v $index`;
            if ($? != 0 || !defined $content_bytes || $content_bytes eq '') {
                warn "Failed to fetch content for index $index. Skipping.\n";
                next;
            }

            # Explicitly decode contents to Perl character string
            my $content = decode_utf8($content_bytes);
            $content =~ s/\e\[[0-9;]*[a-zA-Z]//g;

            # Extract subject from first line / paragraph
            my $subject = '(No Title)';
            if ($content =~ /\A\s*(.+?)\s*(?:\n|$)/) {
                $subject = $1;
            }
            $subject =~ s/^#+\s*//;
            $subject =~ s/\s+$//;

            my $current_time = strftime("%Y-%m-%d %H:%M:%S", localtime);
            my $message_id = "apple-note-" . md5_hex(encode_utf8($content)) . "\@local";

            push @notes_to_sync, {
                index      => $index,
                folder     => $folder,
                subject    => $subject,
                content    => $content,
                date_sent  => $current_time,
                message_id => $message_id,
            };
        }
    }
}
elsif ($IMPORT_MODE eq 'MARKDOWN_FOLDER') {
    print "\n=========================================\n";
    print "Starting sync for Markdown folder: [$MD_FOLDER]\n";
    print "=========================================\n";

    if (!-d $MD_FOLDER) {
        die "Error: Folder '$MD_FOLDER' does not exist.\n";
    }

    my @files;
    # Recursively find all markdown files
    find(sub {
        push @files, $File::Find::name if -f $_ && /\.md$/i;
    }, $MD_FOLDER);

    my $index = 1;
    foreach my $file (@files) {
        # Read contents with UTF-8 encoding
        open my $fh, '<:encoding(UTF-8)', $file or do {
            warn "Could not open file '$file': $!. Skipping.\n";
            next;
        };
        my $content = do { local $/; <$fh> };
        close $fh;

        # Get sub-directory path relative to $MD_FOLDER to determine the Note folder
        my $rel_path = File::Spec->abs2rel($file, $MD_FOLDER);
        my (undef, $directories, $filename) = File::Spec->splitpath($rel_path);

        # Clean folder structure string for context metadata
        my $folder = $directories;
        $folder =~ s{[\\/]+$}{};       # Strip trailing slash/backslash
        $folder =~ s{[\\/]}{ / }g;     # Normalize slashes for visual separation
        $folder = 'Notes' if $folder eq '';

        # Determine the Subject (tries Markdown header first, falls back to filename)
        my $subject = $filename;
        $subject =~ s/\.md$//i; # Strip extension
        if ($content =~ /\A\s*#+\s*(.+?)\s*(?:\n|$)/) {
            $subject = $1;
    }
    $subject =~ s/^\s+|\s+$//g;

    # Retrieve file modification time to preserve date context
    my $mtime = (stat($file))[9];
    my $date_sent = strftime("%Y-%m-%d %H:%M:%S", localtime($mtime));

    # Generate unique message_id based on content MD5 hash
    my $message_id = "markdown-note-" . md5_hex(encode_utf8($content)) . "\@local";

    push @notes_to_sync, {
        index      => $index++,
        folder     => $folder,
        subject    => $subject,
        content    => $content,
        date_sent  => $date_sent,
        message_id => $message_id,
    };
}
}
else {
    die "Unknown IMPORT_MODE: $IMPORT_MODE. Must be 'APPLE_NOTES' or 'MARKDOWN_FOLDER'.\n";
}

# ==========================================
# PROCESS AND SYNC NOTES
# ==========================================
my $synced_count = 0;

foreach my $note (@notes_to_sync) {
    my $index      = $note->{index};
    my $folder     = $note->{folder};
    my $subject    = $note->{subject};
    my $content    = $note->{content};
    my $date_sent  = $note->{date_sent};
    my $message_id = $note->{message_id};

    print "Processing Note Index $index: [$subject]... ";

    # Clean formatting structure and binary chunks
    my $cleaned_body = clean_note_body($content);

    # Truncate extensively long content specifically for the embedding payload
    my $truncated_body = length($cleaned_body) > 1200
    ? substr($cleaned_body, 0, 1200) . " ... [TRUNCATED]"
    : $cleaned_body;

    # Build clean structural context block for vector embedding
    my $text_to_embed = sprintf(
    "Email Folder: %s\n" .
    "From: %s\n" .
    "To: %s\n" .
    "Date: %s\n" .
    "Subject: %s\n\n" .
    "Content:\n%s",
    $MAILBOX,
    ($IMPORT_MODE eq 'MARKDOWN_FOLDER' ? 'Markdown Notes' : 'Apple Notes') . ' (' . $folder . ')',
    $ENV{USER} // 'Local User',
    $date_sent,
    $subject,
    $truncated_body
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
        $IMPORT_MODE eq 'MARKDOWN_FOLDER' ? 'Markdown Notes' : 'Apple Notes',
        $ENV{USER} // 'Local User',
        $date_sent,
        0,
        $cleaned_body,             # Store the full, plain text body in the DB
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

$dbh->disconnect();
print "\n$synced_count notes synchronized.\n";


# ==========================================
# SUBROUTINES / HELPERS
# ==========================================

sub clean_note_body {
    my ($body) = @_;
    return "" unless defined $body;

    # 1. Strip memo's custom image placeholder tokens
    $body =~ s/\[MEMO_IMG_\d+\]//g;

    # 2. Strip long unbroken base64/hex sequences safely using fixed-width lookarounds
    $body =~ s/(?<![A-Za-z0-9])[A-Za-z0-9\+\/=]{80,}(?![A-Za-z0-9])//g;
    $body =~ s/(?<![a-fA-F0-9])[a-fA-F0-9]{80,}(?![a-fA-F0-9])//g;

    # 3. Only run Pandoc if we detect clear signs of rich text (RTF, HTML, complex Markdown).
    if (has_rich_text($body)) {
        # $body = clean_with_pandoc($body);
    }

    # 4. Standard spacing cleanups
    $body =~ s/[ \t]+/ /g;
    $body =~ s/\r//g;
    $body =~ s/\n{3,}/\n\n/g;
    $body =~ s/^\s+|\s+$//g;

    return $body;
}

sub has_rich_text {
    my ($text) = @_;
    return 0 unless defined $text;

    # Clear signs of RTF markup
    return 1 if $text =~ /^\s*\{\\rtf/s;

        # Clear signs of HTML markup
        return 1 if $text =~ /<html/si || $text =~ /<!DOCTYPE/si || $text =~ /<\/?[a-z][a-z0-9]*\b[^>]*>/si;

        # Clear signs of standard Markdown structures.
        return 1 if $text =~ /^\s*#+\s+/m;              # Structural Markdown headers
            return 1 if $text =~ /\[[^\]]+\]\([^)]+\)/;     # Inline links
        return 1 if $text =~ /^[*-]\s+\S+/m;            # Unordered lists
        return 1 if $text =~ /^\d+\.\s+\S+/m;           # Numbered lists
        return 1 if $text =~ /\|[^|]+\|/;                # Tables

        return 0;
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

            # Use standard File::Temp to write safely to disk and avoid pipe deadlock
            my ($fh, $filename);
            eval {
                ($fh, $filename) = tempfile(UNLINK => 1);
            };
            if ($@) {
                warn "Could not create temporary file: $@. Falling back to regex cleanup.\n";
                return clean_fallback_regex($content);
            }

            binmode($fh, ":utf8");
            print $fh $content;
            close $fh;

            # Run pandoc, reading directly from file to pull clean plain text safely
            my $cleaned = '';
            eval {
                open(my $pandoc_out, "-|", "pandoc", "-f", $from_format, "-t", "plain", "--wrap=none", $filename)
                or die "Cannot open pandoc: $!";
                binmode($pandoc_out, ":utf8");
                $cleaned = do { local $/; <$pandoc_out> };
                close $pandoc_out;
            };

            # Fallback checks if execution fails or pathing is missing
            if ($@ || $? != 0 || !defined $cleaned || $cleaned eq '') {
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
