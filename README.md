# MailArchivist: Database & Vector-Powered Email Assistant

MailArchivist is an interactive, desktop-grade conversational email assistant. It combines structured database queries and semantic AI search to query, list, and interact with your email archive. 

Instead of relying on unstable filesystem caches or external binaries, MailArchivist periodically synchronizes your IMAP mailboxes (specifically Gmail/Google Mail) into a **PostgreSQL** database. It generates high-dimensional vector embeddings of your clean email content using **Ollama** and stores them natively using the **`pgvector`** extension, enabling exact semantic search alongside classic keyword queries.

---

## New Architecture

1. **Frontend (Cappuccino / Objective-J)**: A native-feeling single-page desktop-style app running in your browser. It displays your active synchronized mailboxes in a sidebar table and offers a rich chat interface with session save and restore support.
2. **Backend (Mojolicious / Perl)**: A local microservice that manages the conversational agent loop. It uses `Mojo::Pg` to query the PostgreSQL database directly, matches context semantics using `pgvector` cosine similarity, and opens selected messages directly in macOS Mail.app via a native, zero-dependency AppleScript bridge.
3. **Sync Engine (`sync_emails.pl`)**: A standalone, incremental Perl daemon that logs into your IMAP server, checks your database for the last synced folder UIDs, downloads new messages, strips signature blocks/repetitive forward boilerplate, fetches embeddings from Ollama, and inserts them cleanly into the database.

---

## Prerequisites

To run this application, you will need:

* **PostgreSQL** (v12+) with the [pgvector](https://github.com/pgvector/pgvector) extension installed.
* **macOS** with Mail.app configured (used by the JXA/AppleScript bridge when requesting to open physical emails on your screen).
* **Perl 5.20+** with the following CPAN modules installed:
  ```bash
  cpanm Mojolicious Mojo::Pg Mail::IMAPClient Email::MIME DBI DBD::Pg Mojo::UserAgent
  ```
* **Ollama** (Running locally) with:
  * Your embedding model of choice: `bge-m3` (Default, 1024 dimensions).
  * Your conversational tool-calling model: e.g., `gemma4:e4b-mlx` works quite well on a MacBookPro M2/32GB system.

---

## Installation & Setup

### 1. Set Up the Database
Create your database and run the schema setup script inside PostgreSQL to register the tables and the `hnsw` index:

```bash
createdb my_email
psql -d my_email -f setup.sql
```

*(Note: If you are running an older version of `pgvector` (pre-0.5.0), remember to modify the index block in `setup.sql` to use `ivfflat` as instructed in your error logging steps.)*

### 2. Configure and Run the Sync Engine
Open your local copy of `sync_emails.pl` and set up your configurations:

* Provide your IMAP server address (e.g., `imap.gmail.com`).
* Set up your credentials. For Google Accounts, you **must** use a generated [Google App Password](https://support.google.com/accounts/answer/185833).
* Configure your list of target mailboxes inside the `@MAILBOXES` array. (e.g., `'INBOX'`, `'[Google Mail]/Gesendet'`).

Once configured, run your initial synchronization block:

```bash
perl sync_emails.pl
```

*(You can run this script periodically via a cron job or keyboard macro to pull in your latest updates incrementally.)*

### 3. Start the Backend
Start the conversational Mojolicious assistant server:

```bash
morbo ./backend.pl  --listen "http://*:3036"
```

### 4. Deploy the Frontend
Open http://localhost:3036/Frontend/index.html in your browser

---

## Key Features

* **Incremental IMAP Syncing**: Safely resumes syncing from the exact last saved UID per mailbox. Handled entirely via database updates to prevent duplicated message records.
* **Boilerplate Reduction**: The sync script automatically strips standard signature dividers (`--`), email reply chains (`On date, user wrote:`), and forward blocks, ensuring your vector model is only embedding high-value conversational text.
* **Hybrid Search (Keyword + Semantic)**:
  * **Keyword Search**: Uses Postgres indexing for lightning-fast matching of sender names or subjects.
  * **Semantic Vector Search**: Calculates query vectors dynamically and looks up context matches using HNSW-indexed cosine similarity.
* **Native Desktop Window Integration**: When you ask the chatbot to open a message, the backend issues an in-process AppleScript command to tell Mail.app to locate and cleanly activate the target email on your macOS desktop.

---

## Supported Assistant Commands

The chatbot will select tools dynamically based on your request:

* **Conceptual Search**: *"Who was talking about the server budget changes last month?"* (The agent will select `semantic_search_messages`).
* **Metadata Filtering**: *"Show me the last 5 unread messages in [Google Mail]/Gesendet."* (The agent will select `list_messages` with unread constraints).
* **Opening Mail**: *"Open the latest message about our cloud pricing."* (The agent will retrieve the ID and launch Mail.app to focus it).
* **Archive**: *"Archive the subscription receipt from yesterday."*

---

## Configuration

Click on the **"Einstellungen..."** (Settings) menu bar inside the frontend interface to adjust your system configuration:

* **Interface (Schnittstelle)**: Choose between Ollama (Local), Groq, Gemini, or OpenRouter.
* **Model Name (Modellname)**: Define your chat model (e.g., `gemma4:e4b-mlx`).
* **Max Steps**: Set the recursion limit for the agent loop (default: `5`). This protects you from infinite search loops if the model gets stuck.

---

## License

This project is licensed under the MIT License - see the LICENSE file for details.