#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Mail::IMAPClient;
use Email::MIME;
use DBI;
use Mojo::UserAgent;
use Mojo::JSON qw(encode_json decode_json);

# Ensure standard output uses UTF-8 encoding
binmode(STDOUT, ":utf8");

# ==========================================
# CONFIGURATION
# ==========================================
my $IMAP_SERVER   = 'imap.gmail.com';
my $IMAP_USER     = 'XXXX@googlemail.com';
my $IMAP_PASSWORD = 'XXXX XXXX XXXX XXXX'; # Use a Google App Password

# Define your target mailboxes here.
my @MAILBOXES = (
                 'INBOX',
                 '[Google Mail]/Gesendet',
                 '[Google Mail]/Wichtig'
                 );
my $DB_DSN        = 'dbi:Pg:dbname=my_email;host=localhost';
my $DB_USER       = 'postgres';
my $DB_PASS       = 'XXXX';

# NOTE: This model MUST match the $EMBED_MODEL used in backend.pl!
my $OLLAMA_URL    = 'http://localhost:11434/api/embeddings';
my $EMBED_MODEL   = 'mxbai-embed-large'; # Kept consistent with backend.pl (1024 dimensions)

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

my $imap = Mail::IMAPClient->new(
                                 Server   => $IMAP_SERVER,
                                 User     => $IMAP_USER,
                                 Password => $IMAP_PASSWORD,
                                 Ssl      => 1,
                                 Port     => 993,
                                 ) or die "Could not connect to IMAP server: $@";

# Prepared SQL Statements
my $sth_last_uid = $dbh->prepare("SELECT COALESCE(MAX(imap_uid), 0) FROM emails WHERE mailbox = ?");

my $sth_insert_email = $dbh->prepare(q{
                                     INSERT INTO emails (imap_uid, mailbox, message_id, subject, sender, recipient, date_sent, is_unread, body_text, body_html, raw_mime)
                                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                                     ON CONFLICT (message_id) DO UPDATE
                                     SET imap_uid = EXCLUDED.imap_uid, mailbox = EXCLUDED.mailbox
                                     RETURNING id
});

my $sth_insert_embed = $dbh->prepare(q{
                                     INSERT INTO email_embeddings (idemail, embedding)
                                     VALUES (?, ?::vector)
                                     ON CONFLICT (idemail) DO UPDATE SET embedding = EXCLUDED.embedding
});

# ==========================================
# MULTI-MAILBOX SYNC LOOP
# ==========================================
foreach my $mailbox (@MAILBOXES) {
    print "\n=========================================\n";
    print "Starting sync for folder: [$mailbox]\n";
    print "=========================================\n";

    # Select the current folder
    unless ($imap->select($mailbox)) {
        warn "Could not select mailbox [$mailbox]: $@. Skipping.\n";
        next;
    }

    # 1. Fetch the last processed UID for this folder
    $sth_last_uid->execute($mailbox);
    my ($last_uid) = $sth_last_uid->fetchrow_array();
    print "Last synced UID: $last_uid\n";

    # 2. Query IMAP server for newer emails
    my $messages;
    if ($last_uid > 0) {
        $messages = $imap->search("UID " . ($last_uid + 1) . ":*");
    } else {
        $messages = $imap->search("ALL");
    }

    unless ($messages && @$messages) {
        print "No new emails found in [$mailbox].\n";
        next;
    }

    print "Found " . scalar(@$messages) . " potential new messages to sync in [$mailbox].\n";

    # 3. Process each email in folder
    foreach my $uid (@$messages) {
        next if $uid <= $last_uid;

        print "[$mailbox] Processing UID: $uid... ";

        my $raw_mime = $imap->message_string($uid);
        unless ($raw_mime) {
            print "Failed to fetch raw content. Skipping.\n";
            next;
        }

        my $parsed = Email::MIME->new($raw_mime);

        # Parse headers
        my $subject    = $parsed->header('Subject') // '(No Subject)';
        my $sender     = $parsed->header('From')    // '';
        my $recipient  = $parsed->header('To')      // '';
        my $date_sent  = $parsed->header('Date')    // undef;
        my $message_id = $parsed->header('Message-ID');

        if (!$message_id) {
            $message_id = "<fallback-uid-" . $uid . "-" . time() . "\@local>";
        }

        # Extract bodies
        my $body_text = '';
        my $body_html = '';

        $parsed->walk_parts(sub {
            my ($part) = @_;
            return if $part->parts;

            my $content_type = $part->content_type || 'text/plain';
            my $body_decoded = $part->body_str;

            if ($content_type =~ m{text/plain}i) {
                $body_text .= $body_decoded;
            } elsif ($content_type =~ m{text/html}i) {
                $body_html .= $body_decoded;
            }
        });

        # Fallback: Parse body_html to text if body_text was completely missing (transactional emails)
        if (($body_text eq '' || $body_text =~ /^\s*$/) && $body_html ne '') {
            eval {
                require Mojo::DOM;
                my $dom = Mojo::DOM->new($body_html);
                # Strip styling, script blocks, link lists and headers
                $dom->find('style, script, head, link, meta, title')->each(sub { $_->remove });
                $body_text = $dom->all_text;
            };
            if ($@) {
                warn "Could not extract plain text from HTML part: $@\n";
            }
        }

        # Determine unread flag
        my $flags = $imap->flags($uid) // [];
        my $is_unread = (grep { $_ eq '\\Seen' } @$flags) ? 0 : 1;

        # 4. Clean and Format Email
        my $cleaned_body = clean_email_body($body_text);
        my $cleaned_date = clean_date_header($date_sent);

        # 5. Format Structured Context Block (Prose style optimized for sentence embeddings)
        my $text_to_embed = sprintf(
        "Email Folder: %s\n" .
        "From: %s\n" .
        "To: %s\n" .
        "Date: %s\n" .
        "Subject: %s\n\n" .
        "Content:\n%s",
        $mailbox,
        $sender // '(Unknown Sender)',
        $recipient // '(Unknown Recipient)',
        $cleaned_date // '(No Date)',
        $subject // '(No Subject)',
        substr($cleaned_body, 0, 1200) # Kept at 1200 characters for high semantic density
        );

        # 6. Request Vector Embedding
        my $embedding_vector = get_embedding($text_to_embed);

        # 7. Database Transaction with Automatic Date Fallback
        my $success = 0;
        my $inserted_id;

        eval {
            $dbh->begin_work;

            $sth_insert_email->execute(
            $uid,
            $mailbox,
            $message_id,
            $subject,
            $sender,
            $recipient,
            $cleaned_date, # Cleaned RFC-2822 date
            $is_unread,
            $body_text,
            $body_html,
            $raw_mime
            );
            ($inserted_id) = $sth_insert_email->fetchrow_array();
            $dbh->commit;
            $success = 1;
        };

        # Fallback if PostgreSQL rejected the date string syntax
        if ($@) {
            my $err = $@;
            $dbh->rollback;

            if ($err =~ /invalid input syntax for type timestamp/i) {
                print "Invalid date formatting '$cleaned_date'. Retrying with NULL date... ";
                eval {
                    $dbh->begin_work;
                    $sth_insert_email->execute(
                    $uid,
                    $mailbox,
                    $message_id,
                    $subject,
                    $sender,
                    $recipient,
                    undef, # Fall back to NULL (allowed in schema)
                    $is_unread,
                    $body_text,
                    $body_html,
                    $raw_mime
                    );
                    ($inserted_id) = $sth_insert_email->fetchrow_array();
                    $dbh->commit;
                    $success = 1;
                };
                if ($@) {
                    warn "Database error inserting even without date: $@\n";
                    $dbh->rollback;
                }
            } else {
                warn "Database error processing [$mailbox] UID $uid: $err\n";
            }
        }

        # If insert succeeded, commit the embedding vector
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
        }
        if ($@) {
            warn "Database error processing [$mailbox] UID $uid: $@\n";
            $dbh->rollback;
        }
    }
}

$imap->logout();
$dbh->disconnect();
print "\nAll mailboxes synchronized.\n";

# ==========================================
# SUBROUTINES / HELPERS
# ==========================================

sub clean_email_body {
    my ($body) = @_;
    return "" unless defined $body;

    # 1. Strip reply and forwarding chains
    $body =~ s/\n--\s*\n.*$//s;
    $body =~ s/\n\s*On\s+.*?\s+wrote:\s*\n.*$//is;
    $body =~ s/\n\s*Begin forwarded message:\s*\n.*$//is;
    $body =~ s/\n\s*-+\s*Original Message\s*-+\s*\n.*$//is;

    # 2. Strip tracking brackets, hexadecimal codes, and hyperlink noise
    $body =~ s/\[[a-fA-F0-9]{8}\]//g;   # Strip bracketed hexadecimal hashes (e.g. [6CC388AE])
    $body =~ s/<http[^>]+>//g;          # Strip raw links inside brackets
    $body =~ s/https?:\/\/\S+//g;       # Strip plain http/https links

    # 3. Format spacing
    $body =~ s/[ \t]+/ /g;
    $body =~ s/\r//g;
    $body =~ s/\n{3,}/\n\n/g;
    $body =~ s/^\s+|\s+$//g;

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

sub clean_date_header {
    my ($date_str) = @_;
    return undef unless defined $date_str;

    # 1. Strip any parenthesized trailing comments like (UTC), (GMT), (EST)
    $date_str =~ s/\s*\([^)]+\)\s*$//g;

    # 2. Clean leading and trailing whitespaces
    $date_str =~ s/^\s+|\s+$//g;

    # 3. Strip raw timezone text strings if they exist outside of parens (e.g. "UT" or "GMT" at the end)
    $date_str =~ s/\s+[A-Z]{2,4}$//g;

    return $date_str eq '' ? undef : $date_str;
}
