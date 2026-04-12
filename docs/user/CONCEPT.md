# Concept

This document explains the product idea behind the blueprint: what problem it is trying to solve, what principles it follows, who it is for, and what kind of operational experience it is trying to make normal.

## Core idea

The blueprint is meant to make digital sovereignty practical by default for individuals and small organizations.

The point is not simply to run your own software. The point is to run it in a way that is safe enough, recoverable enough, and low-effort enough to remain realistic over time.

That means the project is closer to an operational foundation than to a one-off self-hosting template. It tries to make a small private infrastructure behave like something you can trust and keep using, not something that works only on a good day.

## What problem it addresses

Most people cannot sustainably operate their own infrastructure because it is usually:

- too complex to set up correctly
- too fragile to change with confidence
- too insecure by default
- too time-consuming to maintain
- too dependent on ad hoc operator knowledge

The practical result is predictable: self-hosting often becomes either abandoned, permanently risky, or dependent on a single person who remembers too many hidden details.

This blueprint tries to change that by treating operational safety as part of the product rather than as a separate discipline to be added later.

## What the blueprint tries to make normal

The project aims to make the following defaults feel ordinary rather than advanced:

- security is built in rather than postponed
- backups exist before the first incident rather than after it
- observability is available from the start rather than added during a crisis
- recovery is documented and rehearsable rather than improvised
- adding another service follows a repeatable contract rather than creating a special case

The goal is not infinite flexibility. The goal is safe, understandable repetition.

## Security philosophy

The main security rule is simple: only what must be public is exposed; everything else stays private.

That rule drives several architectural choices across the blueprint:

- minimal public attack surface
- tailnet-first administration instead of public management access
- clear separation between public ingress and internal services
- strong defaults instead of relying on manual hardening after deploy
- explicit acceptance that failure and compromise scenarios must be planned for

This is why the project prefers a public gateway plus private internal services instead of broad public exposure on every machine.

## Operational philosophy

The blueprint is designed to be:

- predictable
- recoverable
- observable
- maintainable over time

It assumes that things will break. The value of the system is not that it avoids all failure. The value is that operators can understand the state of the system, recover it with bounded effort, and add new pieces without losing control of the whole.

In other words, the project is trying to reduce two forms of risk at the same time:

- technical risk, by keeping the exposed surface small and the platform observable
- human risk, by reducing the amount of hidden knowledge required to operate it safely

## Service layer vision

The infrastructure layer exists to support higher-level services such as communication tools, file storage, password managers, and collaboration systems.

The key constraint is that adding a new service should not introduce chaos.

Each service should:

- follow the same deployment structure
- inherit the same private-by-default access model
- integrate into backup and recovery paths automatically
- integrate into logs, metrics, and health checks automatically
- fit the same day-2 operational expectations as the rest of the system

This is the difference between a loose collection of self-hosted applications and a coherent platform foundation.

## Intended users

This blueprint is aimed at:

- individuals who want meaningful control over their data
- families and small teams that need shared services without running a full platform team
- SMBs without a dedicated DevOps function
- privacy-conscious operators who still need practical day-to-day workflows

It is not aimed at large multi-tenant platform operations, nor is it presented as a managed service.

## What success looks like

The project succeeds if a technically aware person can do the following without improvisation:

- deploy the foundation
- understand what is public and what is private
- access services through the expected tailnet workflow
- verify that the system is healthy
- recover after a node failure or workstation loss
- add new services without weakening the overall model

That is a higher bar than "the containers started." It is closer to "the system remains operable after the happy path ends."

## What this project is not

To keep the concept clear, it is worth naming a few non-goals:

- it is not a fully managed platform
- it is not a generic public-cloud abstraction for every possible topology
- it is not trying to optimize for maximum feature count ahead of operational coherence
- it is not treating backups, monitoring, and recovery as optional extras

The project deliberately prefers narrower scope and stronger defaults over broader scope and weaker guarantees.

## Relationship to the roadmap

The concept described here is broader than the currently shipped feature set. The roadmap tracks the work needed to close that gap.

Relevant next-step documents:

- [Blueprint improvement roadmap](../roadmap/blueprint-improvement.md)
- [Internal service template and Vaultwarden design](../roadmap/service-template-and-vaultwarden.md)
- [Architecture](../technical/ARCHITECTURE.md)

## Long-term direction

The long-term goal is straightforward: make running your own infrastructure feel normal rather than exceptional.

That means not unusually risky, not unusually complicated, and not dependent on becoming a full-time sysadmin first.