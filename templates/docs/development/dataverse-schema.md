# Dataverse Schema Standards

Read `docs/agents/development-standards.md` first. This file only adds what is specific to tables, columns and relationships.

## Extend before you create

- Do not create a custom table when a standard table already models the concept. In Customer Service and Field Service that means Account, Contact, Case, Knowledge Article, Entitlement, Work Order, Bookable Resource, Bookable Resource Booking, Resource Requirement and their siblings.
- Extend the standard table with custom columns first. A custom clone loses the out-of-the-box engine attached to the standard table — scheduling, SLA, entitlement, routing — and that engine is usually the reason the platform was chosen.
- Every new table requires an ADR in `docs/adr/` naming the standard table that was considered and why it does not fit.
- Inspect the real metadata before deciding (`describe` via the Dataverse MCP, or `pac`). Never assume a standard table does or does not already have the column you need.

## Naming

- Schema names are PascalCase with the publisher prefix: `{{publisher_prefix}}_WorkOrderCategory`.
- Display names are in English; other languages ship as translations. Never hardcode a translated label.
- Name the concept, not the type: `{{publisher_prefix}}_ApprovalDate`, not `{{publisher_prefix}}_Date2`.
- Every component carries the `{{publisher_prefix}}` prefix. A component created under another publisher is a delivery problem, not a cosmetic one.

## Columns

- Choose the type deliberately and once. Changing the type of a populated column in Dataverse means delete and recreate, with data loss.
- Choice for closed, stable sets the code knows about. Lookup for data the business maintains. Never free text for a state or a category.
- Never model status with a custom text or number column. Use the state/status pair, or a choice.
- Date columns MUST have their behaviour decided explicitly: `User Local` for moments in time, `Date Only` for calendar dates, `Time-Zone Independent` for dates that must not shift. Accepting the default here is what makes a service date move by a day for a technician in another time zone.
- Set precision on decimal and currency columns to what the business requires, not to the default.
- Required, recommended and optional are business decisions, not defaults. A required column that existing data cannot satisfy blocks every future save on that table.
- Set a maximum length that reflects the data instead of leaving every text column at 100.

## Relationships

- Default cascade behaviour is `Referential, Restrict Delete`: it prevents orphans without cascading destructive operations.
- `Parental` only when the child genuinely cannot exist without the parent and must inherit its security.
- Never take `Cascade All` as a default. Each cascaded operation multiplies write cost and can exceed platform limits on a large parent.
- A many-to-many relationship needs justification; an intersect table with its own columns is usually the right answer, because the relationship almost always turns out to carry data.
- Name relationships for the role they express, not `{{publisher_prefix}}_account_case_1`.

## Keys, auditing & data

- Every table that receives data from an external system MUST have an alternate key covering the external identifier, so integrations upsert instead of duplicating.
- Enable auditing per table and per column where it is actually needed. Enabling it globally is a storage and performance cost with no owner.
- Never create business data as a side effect of testing a change. Use DEV data created explicitly for that purpose.

## Verification

- After the change, read the metadata back from the environment and confirm it matches the intent. Never assert from memory what the platform accepted.
- The unpacked solution diff is committed with the change (`scripts/sync-solution.ps1`).
- `pac solution check` reports no high-severity issues. If it could not be run, say so explicitly.
- Deleting or retyping a column, deleting a table or a relationship: prepare the operation and hand it over. A human executes it.
