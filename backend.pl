#!/usr/bin/env perl
# Email Archive Assistant Backend (PostgreSQL & Vector Powered)
use Mojolicious::Lite -signatures;
use Mojo::Pg;
use Mojo::UserAgent;
use Mojo::JSON qw(decode_json encode_json);
use File::Temp qw(tempdir);
use File::Spec;
use Encode;
use Data::Dumper;

no warnings 'uninitialized';

# ==========================================
# CONFIGURATION & HELPERS
# ==========================================
helper pg => sub { state $pg = Mojo::Pg->new('postgresql://postgres@localhost/my_email') };

my $ua = Mojo::UserAgent->new(request_timeout => 0, inactivity_timeout => 0);
$ua->max_connections(0);

my $OLLAMA_EMBED_URL = 'http://localhost:11434/api/embeddings';
my $EMBED_MODEL      = 'mxbai-embed-large'; # Output size: 1024 dimensions

my %SESSIONS;

# ==========================================
# CORS-SUPPORT
# ==========================================
app->hook(before_dispatch => sub ($c) {
    $c->res->headers->header('Access-Control-Allow-Origin'  => '*');
    $c->res->headers->header('Access-Control-Allow-Methods' => 'GET, POST, OPTIONS, PUT, DELETE');
    $c->res->headers->header('Access-Control-Allow-Headers' => 'Content-Type, Authorization, X-Requested-With');
    
    if ($c->req->method eq 'OPTIONS') {
        $c->render(text => '', status => 204);
        return;
    }
});

# ==========================================
# HELPER: Generate Query Embedding
# ==========================================
helper get_query_embedding => sub ($c, $query_text) {
    my $payload = {
        model  => $EMBED_MODEL,
        # Prefix required by mxbai-embed-large for searching document passages
        prompt => "Represent this sentence for searching relevant passages: " . $query_text,
    };
    my $tx = $ua->post($OLLAMA_EMBED_URL => json => $payload);
    if ($tx->result && $tx->result->is_success) {
        my $res = decode_json($tx->result->body);
        return '[' . join(',', @{$res->{embedding}}) . ']';
    }
    return undef;
};

# ==========================================
# DEFINITION OF TOOLS (JSON SCHEMA)
# ==========================================
my @available_tools = (
    {
        type     => 'function',
        function => {
            name        => 'list_accounts_and_mailboxes',
            description => 'Retrieves the list of configured email folders stored in the database.',
            parameters  => { type => 'object', properties => {} }
        }
    },
    {
        type     => 'function',
        function => {
            name        => 'search_messages',
            description => 'Performs standard keyword and sender queries against indexed emails.',
            parameters  => {
                type       => 'object',
                properties => {
                    query => { type => 'string', description => 'The keyword or sender name to search.' },
                    limit => { type => 'integer', description => 'Maximum results (default: 10).' }
                },
                required => ['query']
            }
        }
    },
    {
        type     => 'function',
        function => {
            name        => 'semantic_search_messages',
            description => 'Uses vector embeddings to find emails matching concepts or meanings even if exact keywords are missing.',
            parameters  => {
                type       => 'object',
                properties => {
                    concept => { type => 'string', description => 'The conceptual prompt or semantic meaning.' },
                    limit   => { type => 'integer', description => 'Maximum results (default: 5).' }
                },
                required => ['concept']
            }
        }
    },
    {
        type     => 'function',
        function => {
            name        => 'list_messages',
            description => 'Lists messages within a specific mailbox folder.',
            parameters  => {
                type       => 'object',
                properties => {
                    mailbox => { type => 'string', description => 'The mailbox folder (e.g., "INBOX").' },
                    unread  => { type => 'boolean', description => 'Filter for only unread messages if true.' },
                    limit   => { type => 'integer', description => 'Maximum results. Defaults to 10.' }
                },
                required => ['mailbox']
            }
        }
    },
    {
        type     => 'function',
        function => {
            name        => 'show_message_details',
            description => 'Retrieves the full structural content of an email using its database numeric ID.',
            parameters  => {
                type       => 'object',
                properties => {
                    id => { type => 'integer', description => 'The unique database ID of the email.' }
                },
                required => ['id']
            }
        }
    },
    {
        type     => 'function',
        function => {
            name        => 'archive_message',
            description => 'Sets the archived status flag of an email in the database to true.',
            parameters  => {
                type       => 'object',
                properties => {
                    id => { type => 'integer', description => 'The database ID of the email.' }
                },
                required => ['id']
            }
        }
    },
    {
        type     => 'function',
        function => {
            name        => 'open_message_in_macos_mail',
            description => 'Launches macOS Mail.app and opens the selected email message in its native window.',
            parameters  => {
                type       => 'object',
                properties => {
                    message_id => { type => 'string', description => 'The standard RFC822 Message-ID of the email.' }
                },
                required => ['message_id']
            }
        }
    },
    {
        type     => 'function',
        function => {
            name        => 'web_lookup',
            description => 'Performs an HTTP GET request to fetch and read text or HTML content from a web URL.',
            parameters  => {
                type       => 'object',
                properties => {
                    url => { type => 'string', description => 'The absolute HTTP or HTTPS URL to fetch.' }
                },
                required => ['url']
            }
        }
    }
);

# ==========================================
# HELPER: Dynamic Chat Client
# ==========================================
helper call_chat_llm => sub ($c, $messages, $tools, $config) {
   my $service  = $config->{service}  // 'ollama';
   my $model    = $config->{model}    // '';
   my $api_key  = $config->{api_key}  // '';
   my $endpoint = $config->{endpoint} // '';

   my $promise = Mojo::Promise->new;

   if ($service eq 'ollama') {
       my $url = $endpoint;
       $url =~ s/generate/chat/;
       if ($url eq '') {
           $url = 'http://localhost:11434/api/chat';
       }

       my $payload = {
           model    => $model || 'gemma2:9b-instruct-q8_0',
           messages => $messages,
           stream   => \0
       };
       $payload->{tools} = $tools if $tools && @$tools;

       $ua->post($url => json => $payload => sub ($ua, $tx) {
           if ($tx->result && $tx->result->is_success) {
               my $res = eval { decode_json($tx->result->body) };
               warn Dumper $res;
               my $msg = $res->{message} // { role => 'assistant', content => '' };
               $promise->resolve({
                   role       => 'assistant',
                   content    => $msg->{content} // '',
                   tool_calls => $msg->{tool_calls} // []
               });
           } else {
               my $err_msg = $tx->error ? $tx->error->{message} : "Unknown Connection Error";
               $promise->reject("Ollama Connection Error: " . $err_msg);
           }
       });
   } else {
       $promise->reject("Interface not supported: $service");
   }
   return $promise;
};

# ==========================================
# HELPER: Session State Management
# ==========================================
helper save_session_data => sub ($c, $session_id, $data) {
   $SESSIONS{$session_id} = $data;
   my $tmpdir = File::Spec->tmpdir();
   my $filepath = "$tmpdir/llm_email_session_$session_id.json";
   if (open my $fh, '>', $filepath) {
       print $fh encode_json($data);
       close $fh;
   }
};

helper load_session_data => sub ($c, $session_id) {
   return $SESSIONS{$session_id} if exists $SESSIONS{$session_id};
   my $tmpdir = File::Spec->tmpdir();
   my $filepath = "$tmpdir/llm_email_session_$session_id.json";
   if (-e $filepath) {
       if (open my $fh, '<', $filepath) {
           local $/;
           my $json = <$fh>;
           close $fh;
           my $data = eval { decode_json($json) };
           if ($data) {
               $SESSIONS{$session_id} = $data;
               return $data;
           }
       }
   }
   return;
};

# ==========================================
# RECURSIVE AGENT TOOL CALLING LOOP
# ==========================================
sub run_agent_tool_loop ($c, $messages, $session, $llm_config, $step) {
    my $max_steps = $llm_config->{max_steps} // 5;

    if ($step > $max_steps) {
        return Mojo::Promise->resolve({
            output   => "Maximum analysis steps ($max_steps) reached.",
            attempts => $step
        });
    }

    return $c->call_chat_llm($messages, \@available_tools, $llm_config)->then(sub ($response) {
        my $tool_calls = $response->{tool_calls};

        if ($tool_calls && @$tool_calls) {
            my $tool_call = $tool_calls->[0];
            my $func_name = $tool_call->{function}{name};
            my $args      = $tool_call->{function}{arguments};

            if (!ref $args) {
                $args = eval { decode_json($args) } // {};
            }

            my $result_text = "";
            $c->app->log->info("[Agent DB] Executing Tool Call: $func_name");

            if ($func_name eq 'list_accounts_and_mailboxes') {
                my $boxes = $c->pg->db->query("SELECT DISTINCT mailbox FROM emails")->hashes;
                $result_text = encode_json($boxes);
            }
            elsif ($func_name eq 'search_messages') {
                my $q = '%' . ($args->{query} // '') . '%';
                my $lim = $args->{limit} // 10;
                my $res = $c->pg->db->query(
                    "SELECT id, imap_uid, mailbox, subject, sender, date_sent, is_unread FROM emails " .
                    "WHERE (subject ILIKE ? OR sender ILIKE ? OR body_text ILIKE ?) AND is_archived = FALSE " .
                    "ORDER BY date_sent DESC LIMIT ?", $q, $q, $q, $lim
                )->hashes;
                $result_text = encode_json($res);
            }
            elsif ($func_name eq 'semantic_search_messages') {
                my $concept = $args->{concept};
                my $lim     = $args->{limit} // 15;
                my $vec     = $c->get_query_embedding($concept);
                warn $concept;
                if ($vec) {
                    my $res = $c->pg->db->query(q{
                                                        SELECT e.id, e.subject, e.sender, e.date_sent,
                                                               1 - (emb.embedding <=> ?::vector) AS similarity
                                                        FROM email_embeddings emb
                                                        JOIN emails e ON e.id = emb.idemail
                                                        WHERE e.is_archived = FALSE
                                                        ORDER BY similarity DESC LIMIT ?
                                                    }, $vec, $lim)->hashes;
                    $result_text = encode_json($res);
                } else {
                    $result_text = '{"error":"Failed to compute semantic query vector."}';
                }
            }
            elsif ($func_name eq 'list_messages') {
                my $box = $args->{mailbox};
                my $lim = $args->{limit} // 50;
                my $unread = $args->{unread} ? 1 : 0;
                
                my $sql = "SELECT id, imap_uid, subject, sender, date_sent, is_unread FROM emails WHERE mailbox = ? AND is_archived = FALSE";
                $sql .= " AND is_unread = TRUE" if $unread;
                $sql .= " ORDER BY date_sent DESC LIMIT ?";
                
                my $res = $c->pg->db->query($sql, $box, $lim)->hashes;
                $result_text = encode_json($res);
            }
            elsif ($func_name eq 'show_message_details') {
                my $id = $args->{id};
                my $res = $c->pg->db->query("SELECT * FROM emails WHERE id = ?", $id)->hash;

                if ($res) {
                    # Bereinigt den E-Mail-Text vor der JSON-Kodierung für das LLM
                    if ($res->{body_text} || $res->{raw_mime}) {
                        $res->{body_text} = sanitize_email_text($res->{body_text} || $res->{raw_mime});
                    }
                }
                $result_text = encode_json($res // {});
            }
            elsif ($func_name eq 'archive_message') {
                my $id = $args->{id};
                $c->pg->db->query("UPDATE emails SET is_archived = TRUE WHERE id = ?", $id);
                $result_text = '{"status":"archived","id":' . $id . '}';
            }
            elsif ($func_name eq 'web_lookup') {
                my $url = $args->{url};
                if ($url =~ m{^https?://}i) {
                    my $tx = $ua->get($url);
                    if ($tx->result && $tx->result->is_success) {
                        my $body = $tx->result->body;
                        my $content_type = $tx->result->headers->content_type // '';
                        
                        # Fallback: HTML-Inhalte für das LLM bereinigen
                        if ($content_type =~ /html/i) {
                            $body = _strip_html($body);
                        }
                        
                        # Text kürzen, um das Kontextfenster des Modells nicht zu überladen
                        if (length($body) > 12000) {
                            $body = substr($body, 0, 12000) . "\n\n[... TRUNCATED DUE TO SIZE LIMIT ...]";
                        }
                        
                        $result_text = encode_json({
                            status  => 'success',
                            url     => $url,
                            content => $body
                        });
                    } else {
                        my $err_msg = $tx->error ? $tx->error->{message} : "Unknown Connection Error";
                        $result_text = encode_json({
                            status => 'error',
                            error  => "Failed to retrieve URL. $err_msg"
                        });
                    }
                } else {
                    $result_text = encode_json({
                        status => 'error',
                        error  => "Invalid URL protocol. Only HTTP and HTTPS are supported."
                    });
                }
            }
            else {
                $result_text = "Error: Tool '$func_name' is not implemented.";
            }

            push @$messages, $response;
            push @$messages, {
                role         => 'tool',
                name         => $func_name,
                content      => $result_text,
                tool_call_id => $tool_call->{id} // 'call_id'
            };

            return run_agent_tool_loop($c, $messages, $session, $llm_config, $step + 1);
        } else {
            push @$messages, $response;
            return Mojo::Promise->resolve({
                output   => $response->{content},
                attempts => $step
            });
        }
    });
}

# ==========================================
# ROUTES
# ==========================================

# Fetches mailboxes from database
get '/api/mailboxes' => sub ($c) {
    my $boxes = $c->pg->db->query(q{
                                        SELECT mailbox AS name,
                                        COUNT(*) AS total_count,
                                        COUNT(*) FILTER (WHERE is_unread = TRUE) AS unread_count
                                        FROM emails
                                        GROUP BY mailbox
                                        ORDER BY mailbox
                                    })->hashes;
    warn Dumper $boxes;
    $c->render(json => $boxes);
};

post '/api/chat' => sub ($c) {
   my $payload    = $c->req->json;
   my $session_id = $payload->{session_id};
   $session_id =~ s/[^a-zA-Z0-9_\-]//g if defined $session_id;

   my $user_input = $payload->{prompt};
   my $llm_config = $payload->{llm_config} // {};

   my $session = $c->load_session_data($session_id);
   if (!$session) {
       $session = {
           workdir => tempdir(CLEANUP => 1),
           history => [
               {
                   role    => 'system',
                   content => "You are an intelligent email archivist and assistant managing a synchronized PostgreSQL database of emails.\n"
                            . "You have tools to query keywords, scan folders, pull specific details, perform Semantic Search via vector embeddings, look up web pages, and even trigger macOS Mail.app to open physical emails.\n\n"
                            . "Always select semantic_search_messages if the user query is conversational or conceptual, and standard search_messages for metadata/exact keyword queries.\n"
                            . "Formulate highly structured, readable, and clean summaries of findings."
               }
           ]
       };
   }

   $c->render_later;
   $c->inactivity_timeout(120);

   my $messages = $session->{history};
   push @$messages, { role => 'user', content => $user_input };

   run_agent_tool_loop($c, $messages, $session, $llm_config, 1)->then(sub ($result) {
       $session->{history} = $messages;
       $c->save_session_data($session_id, $session);

       $c->render(json => {
           success    => \1,
           output     => $result->{output},
           attempts   => $result->{attempts},
           downloads  => [],
           thumbnails => []
       });
   })->catch(sub ($err) {
       warn $err;
       $c->render(json => {error => "Agentic workflow error", details => "$err"}, status => 500);
   });
};

use Mojo::DOM;

# ==========================================
# EMAIL SANITIZATION & MIME PARSING
# ==========================================

sub sanitize_email_text ($text) {
    return $text if !$text;

    # 1. Instantly intercept and strip raw binary content (images, PDFs, etc.)
    if (is_binary_data($text)) {
        return "[... BINARY ATTACHMENT STRIPPED ...]";
    }

    # 2. Parse raw MIME structures if present
    if ($text =~ /^(?:Delivered-To|Received|From|To|Subject|MIME-Version|Content-Type|Return-Path):/mi) {
        $text = parse_mime($text);
    }

    # 3. Clean up HTML inputs cleanly using Mojo::DOM
    if ($text =~ /<html|<div|<p|<body|<head/i) {
        $text = _strip_html($text);
    }

    # 4. Clean explicit MIME base64 transfer encoding blocks (safety fallback)
    $text =~ s{Content-Transfer-Encoding:\s*base64\s*[\r\n]+([\s\S]+?)(?=--|\z)}{Content-Transfer-Encoding: base64\n\n[... BASE64 BINARY ATTACHMENT STRIPPED ...]\n}gi;

    # 5. Clean generic massive contiguous blocks of base64-like lines (safety fallback)
    $text =~ s{((?:[A-Za-z0-9+/\\=]{50,85}\r?\n){3,}[A-Za-z0-9+/\\=]{20,85}\r?\n?)}{[... BINARY DATA STRIPPED ...]\n}g;

    # 6. Clean up formatting: Collapse excessive empty newlines into cleaner paragraphs
    $text =~ s/\r//g;
    $text =~ s/\n{3,}/\n\n/g;
    $text =~ s/^\s+|\s+$//g;

    warn $text;
    return $text;
}

sub parse_mime ($text) {
    my ($header_str, $body_str) = split(/\r?\n\r?\n/, $text, 2);
    return $text unless defined $body_str;

    # Parse headers (accounting for line-folding)
    my %headers;
    my $last_key;
    for my $line (split /\r?\n/, $header_str) {
        if ($line =~ /^([a-zA-Z0-9\-]+):\s*(.*)/) {
            $last_key = lc $1;
            $headers{$last_key} = $2;
        } elsif ($line =~ /^\s+(.*)/ && $last_key) {
            $headers{$last_key} .= " " . $1;
        }
    }

    my $content_type = $headers{'content-type'} || 'text/plain';

    # Stop early if this individual part is a non-text binary attachment
    if ($content_type !~ /multipart/i && $content_type !~ /text\/(?:plain|html)/i) {
        my ($filename) = $content_type =~ /name\s*=\s*["']?([^"';\s\r\n]+)["']?/i;
        return $filename ? "[... BINARY ATTACHMENT: $filename STRIPPED ...]" : "[... BINARY ATTACHMENT STRIPPED ...]";
    }

    # If it is a multipart stream, locate boundaries and extract child components
    if ($content_type =~ /multipart\/[a-z]+/i) {
        my ($boundary) = $content_type =~ /boundary\s*=\s*["']?([^"';\s\r\n]+)["']?/i;
        if ($boundary) {
            my $q_boundary = quotemeta($boundary);
            my @parts = split(/--$q_boundary/, $body_str);

            shift @parts if @parts;
            pop @parts if @parts && $parts[-1] =~ /^\s*--\s*$/;

            my @text_parts;
            my @html_parts;

            for my $part (@parts) {
                next if $part =~ /^\s*$/;
                $part =~ s/^\r?\n//;

                my ($part_header_str, $part_body_str) = split(/\r?\n\r?\n/, $part, 2);
                $part_body_str //= '';

                my %part_hdrs;
                my $sub_last_key;
                for my $line (split /\r?\n/, $part_header_str) {
                    if ($line =~ /^([a-zA-Z0-9\-]+):\s*(.*)/) {
                        $sub_last_key = lc $1;
                        $part_hdrs{$sub_last_key} = $2;
                    } elsif ($line =~ /^\s+(.*)/ && $sub_last_key) {
                        $part_hdrs{$sub_last_key} .= " " . $1;
                    }
                }

                my $part_type = $part_hdrs{'content-type'} || 'text/plain';

                if ($part_type =~ /multipart/i) {
                    my $parsed_nested = parse_mime($part);
                    push @text_parts, { body => $parsed_nested } if $parsed_nested;
                } elsif ($part_type =~ /text\/plain/i) {
                    my $transfer_enc = lc($part_hdrs{'content-transfer-encoding'} || '');
                    $transfer_enc =~ s/^\s+|\s+$//g;
                    my $decoded_body = _decode_body($part_body_str, $transfer_enc, $part_type);
                    push @text_parts, { body => $decoded_body };
                } elsif ($part_type =~ /text\/html/i) {
                    my $transfer_enc = lc($part_hdrs{'content-transfer-encoding'} || '');
                    $transfer_enc =~ s/^\s+|\s+$//g;
                    my $decoded_body = _decode_body($part_body_str, $transfer_enc, $part_type);
                    push @html_parts, { body => $decoded_body };
                }
                # Other non-text types (like image/png) are skipped entirely in the multipart loop
            }

            if (@text_parts) {
                return join("\n\n", map { $_->{body} } @text_parts);
            } elsif (@html_parts) {
                return join("\n\n", map { _strip_html($_->{body}) } @html_parts);
            }
            return "";
        }
    }

    # Single-part processing fallback
    my $transfer_enc = lc($headers{'content-transfer-encoding'} || '');
    $transfer_enc =~ s/^\s+|\s+$//g;

    my $decoded_body = _decode_body($body_str, $transfer_enc, $content_type);
    if ($content_type =~ /text\/html/i) {
        return _strip_html($decoded_body);
    }
    return $decoded_body;
}

sub _decode_body ($body, $transfer_enc, $content_type) {
    if ($transfer_enc eq 'quoted-printable') {
        require MIME::QuotedPrint;
        $body = MIME::QuotedPrint::decode_qp($body);
    } elsif ($transfer_enc eq 'base64') {
        require MIME::Base64;
        $body = MIME::Base64::decode_base64($body);
    }

    my ($charset) = $content_type =~ /charset\s*=\s*["']?([^"';\s\r\n]+)["']?/i;
    if ($charset) {
        $charset =~ s/^\s+|\s+$//g;
        my $enc = Encode::find_encoding($charset);
        if ($enc) {
            eval { $body = $enc->decode($body) };
        }
    } else {
        eval { $body = Encode::decode('UTF-8', $body) };
    }

    return $body;
}

sub _strip_html ($html) {
    return '' unless defined $html && $html ne '';
    my $dom = Mojo::DOM->new($html);
    $dom->find('style, script, head, link, meta, title')->each(sub { $_->remove });

    my $text = $dom->all_text;
    $text =~ s/\r//g;
    $text =~ s/\n{3,}/\n\n/g;
    $text =~ s/^\s+|\s+$//g;
    return $text;
}

sub is_binary_data ($text) {
    # Check for well-known binary file signatures (magic bytes) at the very start
    return 1 if $text =~ /^\x89PNG/s;
    return 1 if $text =~ /^\xFF\xD8\xFF/s; # JPEG
    return 1 if $text =~ /^%PDF/s;          # PDF
    return 1 if $text =~ /^GIF8/s;          # GIF

    # Quick, lightweight check: count control characters in the first 1000 bytes.
    # Standard text contains whitespace like \t, \n, \r, and \f, but binary images
    # will contain high densities of control characters (0x00 to 0x08, 0x0E to 0x1F)
    my $sample = substr($text, 0, 1000);
    my $control_count = $sample =~ tr/\x00-\x08\x0B\x0C\x0E-\x1F//;
    return 1 if $control_count > 5;

    return 0;
}

app->config(hypnotoad => {listen => ['http://*:3036'], workers => 1, heartbeat_timeout => 0, inactivity_timeout => 0});
app->start;
