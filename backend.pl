#!/usr/bin/env perl
# LLMDataAnalyst2 - Email Archive Assistant Backend
use Mojolicious::Lite -signatures;
use Mojo::UserAgent;
use Mojo::JSON qw(decode_json encode_json);
use File::Temp qw(tempdir);
use File::Spec;
use Encode;

no warnings 'uninitialized';

my $ua = Mojo::UserAgent->new(request_timeout => 90, inactivity_timeout => 90);
$ua->max_connections(0);

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
# HELPER: Safe mail-app-cli Execution
# ==========================================
sub run_mail_cli {
    my (@args) = @_;
    my $binary = "$ENV{HOME}/go/bin/mail-app-cli";
    unless (-x $binary) {
        $binary = "mail-app-cli"; # Fallback to PATH search
    }
    # Safely escape shell arguments
    my @escaped = map { my $s = $_; $s =~ s/'/'\\''/g; "'$s'" } @args;
    my $cmd = "$binary " . join(" ", @escaped) . " 2>&1";
    my $stdout = `$cmd`;
    return $stdout;
}

# ==========================================
# DEFINITION OF TOOLS (JSON SCHEMA)
# ==========================================
my @available_tools = (
    {
        type     => 'function',
        function => {
            name        => 'list_accounts_and_mailboxes',
            description => 'Retrieves the list of configured email accounts and mailboxes.',
            parameters  => { type => 'object', properties => {} }
        }
    },
    {
        type     => 'function',
        function => {
            name        => 'search_messages',
            description => 'Searches for messages matching a query string across all mailboxes.',
            parameters  => {
                type       => 'object',
                properties => {
                    query => { type => 'string', description => 'The search query or keyword.' },
                    limit => { type => 'integer', description => 'Maximum results. Defaults to 10.' }
                },
                required => ['query']
            }
        }
    },
    {
        type     => 'function',
        function => {
            name        => 'list_messages',
            description => 'Lists messages within a specific mailbox for an account. Supports optional unread filter.',
            parameters  => {
                type       => 'object',
                properties => {
                    account => { type => 'string', description => 'The account name (e.g., "Gmail").' },
                    mailbox => { type => 'string', description => 'The mailbox folder (e.g., "INBOX").' },
                    unread  => { type => 'boolean', description => 'If true, returns only unread messages.' },
                    limit   => { type => 'integer', description => 'Maximum results. Defaults to 10.' }
                },
                required => ['account', 'mailbox']
            }
        }
    },
    {
        type     => 'function',
        function => {
            name        => 'show_message_details',
            description => 'Retrieves the full details (sender, subject, body, headers) of a specific message ID.',
            parameters  => {
                type       => 'object',
                properties => {
                    message_id => { type => 'string', description => 'The message ID.' },
                    account    => { type => 'string', description => 'The account containing the message.' },
                    mailbox    => { type => 'string', description => 'The mailbox containing the message.' }
                },
                required => ['message_id', 'account', 'mailbox']
            }
        }
    },
    {
        type     => 'function',
        function => {
            name        => 'archive_message',
            description => 'Archives a specific message.',
            parameters  => {
                type       => 'object',
                properties => {
                    message_id => { type => 'string', description => 'The message ID.' },
                    account    => { type => 'string', description => 'The account containing the message.' },
                    mailbox    => { type => 'string', description => 'The mailbox containing the message.' }
                },
                required => ['message_id', 'account', 'mailbox']
            }
        }
    },
    {
        type     => 'function',
        function => {
            name        => 'send_email',
            description => 'Sends a new email message.',
            parameters  => {
                type       => 'object',
                properties => {
                    account => { type => 'string', description => 'The account to send from.' },
                    to      => { type => 'string', description => 'Recipient email address.' },
                    subject => { type => 'string', description => 'The subject line.' },
                    body    => { type => 'string', description => 'The message body.' }
                },
                required => ['account', 'to', 'subject', 'body']
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
           model    => $model || 'gemma4:e4b',
           messages => $messages,
           stream   => \0
       };
       $payload->{tools} = $tools if $tools && @$tools;

       $ua->post($url => json => $payload => sub ($ua, $tx) {
           if ($tx->result && $tx->result->is_success) {
               my $res = eval { decode_json($tx->result->body) };
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

   } elsif ($service eq 'groq' || $service eq 'openrouter') {
       my $url = $service eq 'groq' 
           ? 'https://api.groq.com/openai/v1/chat/completions'
           : 'https://openrouter.ai/api/v1/chat/completions';

       my $payload = {
           model       => $model || ($service eq 'groq' ? 'llama3-8b-8192' : 'google/gemini-2.0-flash-001'),
           messages    => $messages,
           temperature => 0.1
       };
       $payload->{tools} = $tools if $tools && @$tools;

       my $headers = {
           'Authorization' => "Bearer $api_key",
           'Content-Type'  => 'application/json'
       };

       $ua->post($url => $headers => json => $payload => sub ($ua, $tx) {
           if ($tx->result && $tx->result->is_success) {
               my $res = eval { decode_json($tx->result->body) };
               my $choice = $res->{choices}[0]{message};
               $promise->resolve({
                   role       => 'assistant',
                   content    => $choice->{content} // '',
                   tool_calls => $choice->{tool_calls} // []
               });
           } else {
               my $err_msg = $tx->error ? $tx->error->{message} : "Unknown Connection Error";
               $promise->reject("Cloud API Error ($service): " . $err_msg);
           }
       });

   } elsif ($service eq 'gemini') {
       my $sel_model = $model || 'gemini-2.5-flash';
       my $url = 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions';

       my $payload = {
           model       => $sel_model,
           messages    => $messages,
           temperature => 0.1
       };
       $payload->{tools} = $tools if $tools && @$tools;

       my $headers = {
           'Authorization' => "Bearer $api_key",
           'Content-Type'  => 'application/json'
       };

       $ua->post($url => $headers => json => $payload => sub ($ua, $tx) {
           if ($tx->result && $tx->result->is_success) {
               my $res = eval { decode_json($tx->result->body) };
               my $choice = $res->{choices}[0]{message};
               $promise->resolve({
                   role       => 'assistant',
                   content    => $choice->{content} // '',
                   tool_calls => $choice->{tool_calls} // []
               });
           } else {
               my $err_msg = $tx->error ? $tx->error->{message} : "Unknown Connection Error";
               $promise->reject("Gemini API Error: " . $err_msg);
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
    if ($step >= 6) {
        return Mojo::Promise->resolve({
            output   => "Maximum analysis steps reached.",
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

            my $result_text;
            $c->app->log->info("[Agent] Executing Tool Call: $func_name");

            if ($func_name eq 'list_accounts_and_mailboxes') {
                my $res_accts = run_mail_cli('accounts', 'list');
                my $res_boxes = run_mail_cli('mailboxes', 'list');
                $result_text = "Accounts:\n$res_accts\n\nMailboxes:\n$res_boxes";
            }
            elsif ($func_name eq 'search_messages') {
                my $q = $args->{query};
                my $lim = $args->{limit} // 10;
                $result_text = run_mail_cli('search', $q, '--limit', $lim) || "[]";
            }
            elsif ($func_name eq 'list_messages') {
                my $acc = $args->{account};
                my $box = $args->{mailbox};
                my $lim = $args->{limit} // 10;
                my @cli_args = ('messages', 'list', '-a', $acc, '-m', $box, '--limit', $lim);
                push @cli_args, '--unread' if $args->{unread};
                $result_text = run_mail_cli(@cli_args) || "[]";
            }
            elsif ($func_name eq 'show_message_details') {
                my $id  = $args->{message_id};
                my $acc = $args->{account};
                my $box = $args->{mailbox};
                $result_text = run_mail_cli('messages', 'show', $id, '-a', $acc, '-m', $box) || "{}";
            }
            elsif ($func_name eq 'archive_message') {
                my $id  = $args->{message_id};
                my $acc = $args->{account};
                my $box = $args->{mailbox};
                $result_text = run_mail_cli('messages', 'archive', $id, '-a', $acc, '-m', $box) || '{"status":"archived"}';
            }
            elsif ($func_name eq 'send_email') {
                my $acc  = $args->{account};
                my $to   = $args->{to};
                my $sub  = $args->{subject};
                my $body = $args->{body};
                $result_text = run_mail_cli('send', '-a', $acc, '-t', $to, '-s', $sub, '--body', $body) || '{"status":"sent"}';
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

# Fetches configured accounts & mailboxes dynamically for left panel view
get '/api/mailboxes' => sub ($c) {
    my $res = run_mail_cli('mailboxes', 'list');
    my $data = eval { decode_json($res) };
    if ($@ || !$data) {
        # Fallback empty list if cli is not configured or fails
        $data = [];
    }
    $c->render(json => $data);
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
                   content => "You are an intelligent email archivist and assistant for macOS Mail.app.\n"
                            . "You have access to a suite of tools that run commands via mail-app-cli to query, view, archive, and send emails.\n\n"
                            . "Always explain your actions clearly, format email lists nicely, and answer user queries with precise context obtained from your tools."
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

app->config(hypnotoad => {listen => ['http://*:3036'], workers => 1, heartbeat_timeout => 0, inactivity_timeout => 0});
app->start;
