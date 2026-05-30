# MailArchivist: Native Tool-Calling Chatbot for macOS Mail.app

MailArchivist is an interactive, desktop-grade web client and backend coordinator that provides a conversational interface for your macOS Mail.app email archive. It leverages a native function-calling agentic loop to search, list, read, archive, and send emails directly through your configured Mail.app accounts.

The project is built using a **Cappuccino (Objective-J)** frontend to deliver a desktop-like user interface and a lightweight **Mojolicious (Perl)** backend that maps LLM tool definitions directly to CLI commands.

---

## Architecture

1. **Frontend (Cappuccino / Objective-J)**: A native-feeling single-page desktop-style app running in the browser. It displays your configured mailboxes in a sidebar table and features a fully-featured chat panel with session transfer capabilities.
2. **Backend (Mojolicious / Perl)**: A local microservice that coordinates chat history, executes agentic function-calling cycles, and safely runs local commands via `mail-app-cli`.
3. **CLI Layer (`mail-app-cli`)**: A Go-based command-line interface that controls macOS Mail.app natively using AppleScript and JavaScript for Automation (JXA).

---

## Prerequisites

To run this application, you will need:

* **macOS** with Mail.app configured with at least one active email account.
* **Go 1.21+** (for compiling `mail-app-cli`).
* **Perl 5.20+** with the following CPAN modules installed:
  * `Mojolicious`
* **An LLM Provider**:
  * **Ollama** (Running locally, e.g., with `gemma4:e4b` or another tool-capable model).
  * Or API keys for **Groq**, **Google Gemini**, or **OpenRouter**.

---

## Installation & Setup

### 1. Install `mail-app-cli`
Install the command-line helper from source using Go:

```bash
go install github.com/intelligrit/mail-app-cli@latest
```

Ensure the compiled binary is available at `~/go/bin/mail-app-cli` (or is in your system's `PATH`). You can verify your installation by listing your configured Mail.app accounts:

```bash
~/go/bin/mail-app-cli accounts list
```

### 2. Set Up the Backend
Clone this repository and ensure the Perl dependencies are installed. You can install Mojolicious via `cpanm`:

```bash
cpanm Mojolicious
```

Run the Mojolicious backend server:

```bash
perl app.pl daemon -l http://localhost:3036
```

### 3. Open the Frontend
Deploy the Cappuccino build folder on your local web server or open the development index file. If the backend is running on a different port or host than `http://localhost:3036`, you can configure the `BackendBaseURL` at the top of your `AppController.j`:

```objc
var BackendBaseURL = @"http://localhost:3036";
```

---

## Features

* **Visual Mailbox Overview**: On startup, the frontend requests your Mail.app directory structure and populates a left-hand sidebar containing accounts, mailbox names, and unread counters.
* **Conversational Agent Loop**: The backend manages structured function-calling cycles (up to 5 recursive turns per prompt), allowing the LLM to search for a message, retrieve its details, make a decision, and execute further actions if necessary.
* **Local and Cloud LLM Integration**: Change interface providers directly inside the app using the configuration modal. Supports local Ollama instances and cloud API endpoints (Groq, Gemini, and OpenRouter).
* **Session Management**: Export and import entire chat histories using a unified JSON transfer panel. This lets you save conversations or resume them in a later session.

---

## Supported Assistant Commands

Your configured LLM can perform complex actions on your behalf by combining its tool schemas:

* **Search**: *"Suchen Sie nach E-Mails von Daniel über das neue Budget."*
* **List & Filter**: *"Zeige mir die letzten 5 ungelesenen E-Mails in meinem Posteingang."*
* **Retrieve Details**: *"Was steht in der neuesten E-Mail von GitHub?"*
* **Archive & Clean**: *"Archiviere bitte die Benachrichtigungs-E-Mail mit der ID xxxx."*
* **Send Drafts**: *"Sende eine E-Mail an Daniel (daniel@example.com) mit dem Betreff 'Update' und dem Inhalt 'Ich habe das System aufgesetzt'."*

---

## Configuration

Click on the **"Einstellungen..."** (Settings) button in the upper menu bar of the frontend to configure your LLM:

* **Schnittstelle (Interface)**: Choose between Ollama, Groq, Gemini, or OpenRouter.
* **Modellname (Model name)**: Specify the model (e.g., `gemma4:e4b` or `google/gemini-2.0-flash-001`).
* **API-Schlüssel (API Key)**: Provide your provider authentication token when using cloud models.

---

## License

This project is licensed under the MIT License - see the LICENSE file for details.