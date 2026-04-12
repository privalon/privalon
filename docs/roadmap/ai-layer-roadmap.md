**Sovereign Cloud AI Layer**

Architecture, Design & Implementation Roadmap

AI Configurator + AI Organizations Layer --- Depends on Blueprint Phase
completion

March 2026 · Working Document v1.0

**Prerequisites**

The AI layer cannot be built in isolation. It depends on the blueprint
layer being solid first. Specifically, the following must be true before
AI work begins:

-   Terraform modules for at least two providers (Hetzner + ThreeFold)
    are working and tested

-   Config schema exists: a validated parameter set that fully defines a
    deployment

-   All Tier 1 services have working Ansible roles with defined data
    directories

-   Backup is implemented and tested --- restore drill passes

-   The runbook exists and a non-author has successfully used it

+-----------------------------------------------------------------------+
| **Why this order matters**                                            |
|                                                                       |
| The AI configurator\'s job is to fill in a config schema through      |
| conversation and then run deployment. If the schema does not exist    |
| yet, there is nothing to fill in. Building AI first would mean        |
| building on shifting ground --- every blueprint change would break    |
| the AI layer.                                                         |
+-----------------------------------------------------------------------+

**Part 1: AI Deployment Configurator**

The configurator is the first AI feature --- the one that converts a
natural-language conversation into a validated deployment. It is what
makes the blueprint accessible to non-technical users without requiring
them to edit config files.

**1.1 Architectural Principle**

The AI is a configurator, not a generator. It does not write Terraform
or Ansible code. It populates a validated parameter schema through
conversation. The infrastructure code never changes --- only the
parameters change.

+---------------------------------+------------------------------------+
| **What AI must NOT do**         | **What AI must DO**                |
|                                 |                                    |
| Generate Terraform or Ansible   | Ask questions and collect          |
| code                            | parameter values                   |
|                                 |                                    |
| Modify infrastructure modules   | Validate inputs against schema in  |
|                                 | real time                          |
| Execute commands with no human  |                                    |
| confirmation                    | Explain trade-offs in plain        |
|                                 | language                           |
| Handle secrets or credentials   |                                    |
| directly                        | Present config summary and ask for |
|                                 | confirmation                       |
| Make deployment decisions       |                                    |
| autonomously                    | Trigger deployment only after      |
|                                 | explicit user approval             |
+---------------------------------+------------------------------------+

**1.2 Conversation Flow Design**

The conversation follows a fixed structure. The AI guides the user
through five stages: provider selection, infrastructure sizing, service
selection, backup configuration, and confirmation. At no stage does the
user need to know what a tfvars file is.

**Stage 1: Provider**

-   Ask where they want to host --- present 2-3 options with brief
    descriptions

-   Explain cost implications (estimated monthly cost per option)

-   Collect: provider name, region, API credentials guidance (not the
    credentials themselves)

**Stage 2: Infrastructure**

-   Recommend a default topology based on selected services

-   Explain what each VM does in plain language

-   Collect: VM sizes, node count, whether they want a backup node

**Stage 3: Services**

-   Present services as what they replace, not what they are (\"replaces
    Google Drive\" not \"Nextcloud\")

-   Group by category: files, communication, security, developer tools

-   Automatically include dependencies (selecting Matrix adds Element
    automatically)

-   Collect: which services to enable, custom domain for each

**Stage 4: Backup**

-   This stage is mandatory --- cannot be skipped

-   Explain why backup on a different provider matters

-   Collect: primary backup target, secondary backup target, retention
    preferences

**Stage 5: Confirmation**

-   Show complete config summary in plain language

-   Show estimated monthly cost breakdown

-   Show what data will be generated (admin password, VPN keys, backup
    key)

-   Require explicit confirmation before any deployment command is run

-   After confirmation: generate config files, show deployment command,
    user runs it

**1.3 LLM Provider Strategy**

The configurator must work with any LLM --- this is a philosophical and
practical requirement. Philosophical: users who want digital sovereignty
should not be forced to trust an external AI provider. Practical: local
LLMs are improving rapidly and will serve most configuration tasks well.

-   Design the configurator as a structured prompt system, not a custom
    model

-   System prompt defines the conversation structure, validation rules,
    and output format

-   Compatible with: Claude API, OpenAI API, local Ollama (Llama 3,
    Mistral, Phi)

-   Local LLM is the recommended default for the sovereignty-focused
    user

-   Document which local models work well --- test and publish benchmark
    results

+-----------------------------------------------------------------------+
| **Monetization note**                                                 |
|                                                                       |
| If AI runs locally, there is no per-query cost to the user.           |
| Monetization is a license for the configurator software itself, not a |
| usage charge. This is philosophically consistent and practically      |
| simpler.                                                              |
+-----------------------------------------------------------------------+

**1.4 Technical Implementation**

**Schema-first design**

-   Define the full parameter schema in JSON Schema or equivalent before
    writing any AI code

-   Every parameter: type, allowed values, default, description,
    dependencies

-   AI collects values against this schema --- validation is
    schema-level, not prompt-level

-   Same schema used by both AI configurator and manual config editing

**Guardrail architecture**

-   AI output is always a structured JSON object matching the schema ---
    never free-form config

-   JSON output is validated against schema before being written to disk

-   Invalid output from AI is rejected --- AI is asked to retry, not
    silently fixed

-   No AI output ever touches the Terraform or Ansible code layer

**Conversation state**

-   Conversation state is local --- stored in a session file, never sent
    to any external service

-   User can interrupt and resume configuration at any stage

-   Partially-completed configurations are saved and resumable

  --------------------- ------------- -------------- -------------------------
  **Component**         **Current     **Priority**   **What\'s Needed**
                        State**                      

  Schema definition     Does not      Critical       JSON schema for all
                        exist                        parameters

  Conversation flow     Not designed  Critical       5-stage structured
                                                     dialogue

  LLM compatibility     Not tested    High           Test Claude, OpenAI,
                                                     Ollama

  Schema validation     Not           Critical       Validate AI output before
                        implemented                  write

  Local LLM support     Not           High           Ollama integration +
                        implemented                  model guide

  Resumable sessions    Not           Medium         Session file persistence
                        implemented                  
  --------------------- ------------- -------------- -------------------------

**Part 2: AI Organizations Layer**

The AI Organizations layer is the second home run product --- the
premium tier that sits on top of the free blueprint. It deploys
persistent AI agent teams inside the user\'s sovereign perimeter. Agents
have their own Matrix identities, email addresses, and task queues. They
run on the user\'s hardware. They never call home.

+-----------------------------------------------------------------------+
| **Timing note**                                                       |
|                                                                       |
| This part should not be built until the blueprint layer is mature and |
| the configurator is working. It is described here for design          |
| continuity, not as immediate work. Come back to this section after    |
| the blueprint phase is complete.                                      |
+-----------------------------------------------------------------------+

**2.1 What an AI Organization Is**

An AI organization is a team of persistent agents deployed inside the
user\'s sovereign infrastructure. Each agent has a defined role, a
Matrix identity, an email address, and a task queue. Agents receive
tasks via Matrix messages or email, process them using a local or
licensed LLM, and respond through the same channels.

From the user\'s perspective: they have a team of AI assistants who live
inside their own private cloud, can be messaged like colleagues, and
have no external dependencies.

**2.2 Core Architecture**

**Agent identity layer**

-   Each agent: a Matrix account on the user\'s Synapse server

-   Each agent: an email address on the user\'s Stalwart mail server

-   Agent identities are provisioned by Ansible at org creation time

-   Agents are addressable from any Matrix client or email client

**Agent runtime**

-   Agent runner: lightweight Python or Go service, one per agent

-   Listens on Matrix room and email inbox for incoming tasks

-   Passes task to LLM with role-specific system prompt

-   Responds via Matrix message or email reply

-   Runs as a systemd service inside the sovereign perimeter

-   No persistent connection to external services

**Task queue**

-   Tasks arrive via Matrix DM or email --- no custom API needed

-   Agent processes one task at a time by default (configurable)

-   Task history stored locally in agent\'s data directory

-   Tasks can be delegated between agents via Matrix room mentions

**LLM provider options (same as configurator)**

-   Local Ollama --- default, no external dependency, runs on user\'s
    VMs

-   Licensed remote API (Claude, OpenAI) --- opt-in, user provides their
    own API key

-   Hybrid: local LLM for routine tasks, remote API for complex
    reasoning

**2.3 Org Chart Model**

Agents are organized in a hierarchy that mirrors a real team. The user
interacts with their org the same way they would with human colleagues
--- via message.

  --------------- ----------------------- ---------------------------------------
  **Role**        **Matrix Address**      **Responsibilities**

  Chief of Staff  \@chief@yourdomain      Routes incoming tasks, summarizes
                                          status, escalates to user

  Researcher      \@research@yourdomain   Web search, document analysis,
                                          synthesis, briefings

  Writer          \@writer@yourdomain     Drafts documents, emails, summaries on
                                          request

  Developer       \@dev@yourdomain        Code review, debugging help,
                                          documentation generation

  Ops Monitor     \@ops@yourdomain        Infrastructure health checks, alerts,
                                          service status reports

  Custom Role     \@custom@yourdomain     User-defined role with custom system
                                          prompt
  --------------- ----------------------- ---------------------------------------

**2.4 Multi-Organization Support**

A single sovereign infrastructure can host multiple independent AI
organizations --- for example, personal org and business org, or
multiple client orgs for a consultant. Each organization is isolated at
the Ansible level: separate Matrix rooms, separate email domains or
subdomains, separate data directories, separate LLM context.

-   Multiple orgs on same VM fleet --- resource-efficient

-   Org isolation: Matrix spaces, separate email domains, no cross-org
    context leakage

-   Org creation via blueprint configurator --- add-org operation

-   Each org has its own admin user and its own agent roster

**2.5 Privacy Architecture**

This is the defining feature: everything runs inside the user\'s
perimeter. No agent task, no conversation, no document ever leaves the
user\'s infrastructure unless they explicitly forward it.

-   Agent runner has no outbound connections by default

-   LLM runs locally (Ollama) --- no API calls to external providers

-   Task history stored in encrypted data directory backed up with rest
    of infrastructure

-   If user opts in to remote LLM API: their API key, their billing,
    their responsibility

-   No telemetry, no usage reporting, no call-home

**2.6 Monetization Model for AI Organizations**

The AI organizations layer is a licensed software product, not a SaaS
subscription. The user buys a license that activates the agent
deployment tooling. Everything runs on their hardware.

  ------------------ ------------- ---------------------------------------
  **Tier**           **Annual      **What\'s included**
                     Price**       

  Free (Blueprint)   €0            Full open-source blueprint, deploy
                                   yourself, community support

  Personal AI Org    €120 / yr     1 AI organization, up to 5 agents, AI
                                   configurator license

  Team AI Org        €480 / yr     3 AI organizations, up to 20 agents,
                                   priority support

  Multi-Org          €1,200 / yr   Unlimited organizations, consultant/MSP
                                   use, partner listing
  ------------------ ------------- ---------------------------------------

**2.7 Implementation Sequence**

Building AI organizations requires the following work, in order:

1.  Agent identity provisioning: Ansible roles to create Matrix accounts
    and email addresses for agents

2.  Agent runner: minimal service that listens on Matrix/email and calls
    LLM

3.  Ollama integration: deploy Ollama on services VM, configure agents
    to use it

4.  Role library: 5 default agent system prompts (Chief of Staff,
    Researcher, Writer, Developer, Ops)

5.  Org management: add-org and remove-org operations in the blueprint

6.  Multi-org isolation: Matrix spaces, separate email domains, context
    separation

7.  AI configurator for orgs: extend configurator to handle org creation
    conversation

8.  License activation: local license check, no call-home beyond
    activation ping

  --------------------- ------------ -------------- -------------------------
  **Component**         **Current    **Priority**   **What\'s Needed**
                        State**                     

  Agent identity layer  Does not     Foundation     Ansible roles for
                        exist                       Matrix + email accounts

  Agent runner service  Does not     Foundation     Matrix/email listener +
                        exist                       LLM bridge

  Ollama integration    Does not     Foundation     Deploy + configure local
                        exist                       LLM

  Default role library  Does not     High           5 system prompts, tested
                        exist                       and tuned

  Org management ops    Does not     High           add-org, remove-org
                        exist                       blueprint commands

  Multi-org isolation   Does not     Medium         Separation architecture +
                        exist                       testing

  License system        Does not     Medium         Local activation, single
                        exist                       ping validation
  --------------------- ------------ -------------- -------------------------

**Overall AI Layer Timeline**

This is an approximate sequence. Part 1 (configurator) depends on
blueprint being complete. Part 2 (organizations) depends on Part 1 being
stable.

  ----------- ------------- ------------------- ------------------------------
  **Phase**   **When**      **Deliverable**     **Depends on**

  A1          After         Config schema +     Blueprint runbook complete
              blueprint     validation          
              Phase 6                           

  A2          After A1      Conversation flow + Schema exists and stable
                            LLM integration     

  A3          After A2      Local LLM (Ollama)  Configurator working with
                            support + test      Claude API

  A4          After A3      Beta with real      Ollama integration stable
                            users               

  B1          After A4      Agent runner +      Configurator in beta
                            Matrix integration  

  B2          After B1      Default role        Agent runner stable
                            library (5 roles)   

  B3          After B2      Ollama-powered      Roles tested
                            agents              

  B4          After B3      Multi-org + license Single-org working in
                            system              production
  ----------- ------------- ------------------- ------------------------------

+-----------------------------------------------------------------------+
| **Remember: AI is not the moat**                                      |
|                                                                       |
| The configurator can be replicated by pointing any LLM at good        |
| documentation. The moat is the certified blueprint registry, the      |
| community trust, and the AI organizations layer as a complete         |
| locally-running product. Build the foundation well and the AI layer   |
| becomes valuable --- without the foundation, it is a demo.            |
+-----------------------------------------------------------------------+

*End of Document*
