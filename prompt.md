# RFC Responsible Owner Management System

## Objective

Implement a complete Responsible Owner Management system for the existing React Single Page Application hosted on GitLab Pages.

The solution must allow users to:

* View responsible owners for an RFC
* Add owners
* Remove owners
* Edit owners
* Assign entire Pods
* Assign custom users
* Assign external users not present in lookup data
* Generate Microsoft Teams hyperlinks automatically when email information is available
* Track ownership changes
* Persist ownership changes through GitLab CI/CD
* Publish updates automatically to GitLab Pages

The application is entirely static and has no backend service.

GitLab CI/CD acts as the persistence layer.

---

# Architecture Overview

The solution consists of:

1. React UI
2. Static JSON data
3. GitLab Pipeline Trigger
4. Ownership Processing Pipeline
5. GitLab Pages Deployment

Flow:

```text
User edits Responsible owners
        ↓
User clicks Save
        ↓
React generates ownership change payload
        ↓
Trigger GitLab pipeline on feature/owners
        ↓
CI validates payload
        ↓
CI merges into data/owners.json
        ↓
CI commits changes
        ↓
CI pushes feature/owners
        ↓
fetch-data job runs
        ↓
React app rebuilt
        ↓
GitLab Pages refreshed
```

---

# Core Design Principles

1. Ownership assignments are free-form.
2. The lookup database is only used for:

   * User discovery
   * Autocomplete
   * Pod expansion
   * Email enrichment
   * Teams hyperlink generation
3. The lookup database must never restrict ownership assignment.
4. Users must be able to assign:

   * Known users
   * Unknown users
   * Vendors
   * Contractors
   * Teams
   * Groups
   * Custom text entries
5. Failure to find a lookup record is not an error.
6. React must never modify `data/owners.json` directly.
7. GitLab CI is the only component allowed to update ownership data.

---

# RFC Data Model

Each RFC row contains a unique RFC number.

Example:

```json
{
  "rfcNumber": "RFC-12345",
  "title": "Implement Authentication Service"
}
```

RFC Number is the unique identifier used for ownership assignments.

---

# JSON Schemas

```typescript
export interface ResponsibleOwner {
  name: string;
  email?: string;
}

export interface LookupUser {
  id?: string;
  name: string;
  email?: string;
  podName?: string;
}

export type OwnersFile = Record<
  string,
  ResponsibleOwner[]
>;
```

---

# Data Sources

## User Lookup File

Location:

```text
data/users.json
```

Example:

```json
[
  {
    "id": "u1",
    "name": "John Smith",
    "email": "john.smith@company.com",
    "podName": "Payments"
  },
  {
    "id": "u2",
    "name": "Jane Doe",
    "email": "jane.doe@company.com",
    "podName": "Payments"
  },
  {
    "id": "u3",
    "name": "Robert Brown",
    "email": "robert.brown@company.com",
    "podName": "Platform"
  }
]
```

Rules:

* id is optional
* email may be empty
* podName may be empty
* podName is optional
* multiple users may belong to the same pod

Purpose:

* User autocomplete
* Pod lookup
* Email enrichment
* Teams link generation

The UI is read-only with respect to users.json.

Users cannot modify lookup data.

---

## Ownership File

Location:

```text
data/owners.json
```

Example:

```json
{
  "RFC-12345": [
    {
      "name": "John Smith",
      "email": "john.smith@company.com"
    },
    {
      "name": "Architecture Team"
    }
  ],
  "RFC-98765": [
    {
      "name": "Michael Johnson"
    }
  ]
}
```

Rules:

* RFC may not exist
* RFC may have zero owners
* RFC may have one owner
* RFC may have many owners

This file is the source of truth.

---

# GitLab Configuration Discovery

The Responsible Owner feature must reuse the existing status.json file already loaded by the application.

Example:

```json
{
  "gitlab": {
    "projectId": "12345",
    "projectUrl": "https://gitlab.example.com/group/project",
    "triggerUrl": "https://gitlab.example.com/api/v4/projects/12345/trigger/pipeline",
    "triggerToken": "xxxxxxxxxxxxxxxx",
    "ownershipBranch": "feature/owners"
  }
}
```

The application must:

* Load status.json
* Read GitLab configuration values
* Use the configured trigger URL
* Use the configured trigger token
* Use the configured ownership branch
* Avoid hardcoded project IDs, URLs, branch names, or tokens

The trigger token must be a dedicated GitLab Pipeline Trigger Token.

It must not be a Personal Access Token or Project Access Token.

---

# Application Startup

On application startup:

1. Load RFC dataset.
2. Load users.json.
3. Load owners.json.
4. Merge ownership data into RFC rows using RFC number.

Example:

```typescript
const owners =
  ownersJson[row.rfcNumber] ?? [];
```

---

# Responsible Column

Add a new table column:

```text
Responsible
```

Position:

* Near the end of the table
* Before Actions column if one exists

---

# Display Mode

Default state.

Display owners as compact tags.

Example:

```text
[John Smith] [Architecture Team]
```

---

# Teams Hyperlink Generation

If an owner contains an email:

```json
{
  "name": "John Smith",
  "email": "john.smith@company.com"
}
```

Generate:

```text
https://teams.microsoft.com/l/chat/0/0?users=john.smith@company.com
```

Requirements:

* Open in a new tab
* rel="noopener noreferrer"

---

# Automatic Lookup Resolution

If an owner contains only a name:

```json
{
  "name": "John Smith"
}
```

Attempt lookup enrichment.

Match order:

1. Exact email
2. Exact name
3. Case-insensitive name

If a single unique match exists:

* Resolve email
* Render Teams hyperlink

If no match exists:

* Render as plain text

---

# Lookup Ambiguity Handling

If multiple lookup users have the same name:

Example:

```text
John Smith -> john.smith@company.com
John Smith -> john.smith2@company.com
```

The system must not automatically resolve ownership.

Render as plain text.

Require explicit user selection during edit mode.

---

# Unassigned State

Display:

```text
Unassigned
```

using muted styling.

---

# Edit Mode

Users can enter edit mode by:

* Double-click
* Edit icon
* Pressing Enter while focused

Editing must occur inline.

No modal dialogs.

---

# Editable Tags

Example:

```text
John Smith ×
Architecture Team ×
```

Requirements:

* Instant removal
* Use stopPropagation()
* Must not trigger hyperlinks
* Must not exit edit mode

---

# Search and Autocomplete

Typing:

```text
@john
```

opens a dropdown.

Search fields:

* name
* email
* podName

Matching:

* case-insensitive
* partial match

---

# Pod Support

Pods are logical groups of users.

Example:

```json
{
  "id": "u1",
  "name": "John Smith",
  "email": "john.smith@company.com",
  "podName": "Payments"
}
```

---

# Pod Search

Typing:

```text
@pay
```

returns:

```text
📁 Payments Pod
John Smith
Jane Doe
```

Pod matches should appear before individual user matches.

---

# Pod Expansion

Selecting:

```text
📁 Payments Pod
```

must automatically expand into all users belonging to that pod.

Example:

```json
[
  {
    "name": "John Smith",
    "email": "john.smith@company.com"
  },
  {
    "name": "Jane Doe",
    "email": "jane.doe@company.com"
  }
]
```

---

# Historical Pod Behaviour

Pod assignments are expanded into users during save.

Persist only expanded users.

Do not persist pod names.

Future pod membership changes must not alter historical RFC ownership records.

---

# Duplicate Detection

Duplicate detection must be case-insensitive.

Deduplicate by:

1. email
2. id
3. name

Examples:

```text
John Smith
JOHN SMITH
```

must be treated as the same owner.

---

# Custom and Unknown Owners

All of the following are valid:

```json
{
  "name": "John Smith",
  "email": "john.smith@company.com"
}
```

```json
{
  "name": "Michael Johnson"
}
```

```json
{
  "name": "Architecture Team"
}
```

```json
{
  "name": "External Vendor"
}
```

No lookup match is required.

---

# Custom Owner Creation

If no match exists:

Display:

```text
Add "Michael Johnson"
```

Selecting it creates:

```json
{
  "name": "Michael Johnson"
}
```

---

# Keyboard Navigation

Support:

* Arrow Up
* Arrow Down
* Enter
* Escape
* Tab
* Backspace

Backspace removes the last tag when input is empty.

---

# Save and Cancel

Provide:

```text
Save
Cancel
```

buttons.

---

# Change Detection

Compare:

```typescript
originalOwners
```

and

```typescript
editedOwners
```

Comparison must include:

* count
* names
* emails
* ordering

---

# No Change Scenario

If arrays are identical:

```typescript
{
  hasChanged: false
}
```

Exit edit mode.

Do not trigger persistence.

---

# Modified RFC Tracking

Track only modified RFC assignments.

Type:

```typescript
Record<string, ResponsibleOwner[]>
```

---

# Save Workflow

When Save is clicked:

1. Validate ownership assignments.
2. Generate modified RFC payload.
3. Base64 encode payload.
4. Trigger GitLab pipeline.
5. Update local React state immediately.
6. Exit edit mode.
7. Display success notification.

Example:

```text
Ownership update submitted successfully.
```

Users should not wait for GitLab Pages deployment.

Changes should remain visible in the current browser session immediately after Save.

---

# Pipeline Trigger Request

```http
POST {triggerUrl}

token={triggerToken}
ref={ownershipBranch}
variables[OWNERSHIP_UPDATE]={base64EncodedPayload}
```

Payload must contain only modified RFCs.

---

# Pipeline Trigger Failure

If pipeline trigger fails:

* Keep local edits intact
* Do not discard ownership changes
* Display error notification
* Allow retry
* Do not overwrite local state

Example:

```text
Failed to submit ownership update. Please try again.
```

---

# GitLab Pipeline Stages

```yaml
stages:
  - preprocess
  - fetch-data
  - build
  - pages
```

---

# Branch Restrictions

Ownership processing jobs must run only on:

```text
feature/owners
```

Never run on:

* main
* master
* merge requests
* tags

---

# Preprocess Stage

Job:

```text
process-owner-updates
```

Responsibilities:

1. Read OWNERSHIP_UPDATE.
2. Decode payload.
3. Validate JSON.
4. Validate RFC keys.
5. Validate owner names.
6. Load data/owners.json.
7. Merge changes.
8. Remove duplicates.
9. Sort RFC keys alphabetically.
10. Save updated file.
11. Commit changes.
12. Push feature/owners.

---

# Empty Ownership Handling

RFCs with no owners must remain in owners.json.

Example:

```json
{
  "RFC-12345": []
}
```

Do not delete RFC keys.

---

# Merge Strategy

Only update RFCs present in payload.

Existing RFCs not included in the payload must remain unchanged.

---

# Conflict Resolution

Multiple users may update RFC ownership simultaneously.

Updates are applied RFC-by-RFC.

The latest successfully merged pipeline update becomes authoritative.

Last successful pipeline merge wins.

---

# Commit Message

Example:

```text
Update RFC ownership assignments
```

---

# Automation Loop Prevention

The preprocess job must ignore commits authored by the ownership automation account.

Ownership update commits must not trigger ownership processing again.

Use:

* Commit message markers
* CI rules
* Commit author validation

to prevent infinite pipeline loops.

---

# Fetch Data Stage

Responsibilities:

Download latest:

```text
data/users.json
data/owners.json
```

Expose files as artifacts for the build stage.

---

# Build Stage

Build React application using the latest ownership and lookup data.

---

# Pages Stage

Publish updated GitLab Pages site.

Ownership updates should become visible after deployment completes.

---

# Auditability

Git history on feature/owners acts as the audit trail.

Every ownership change must be recoverable through commit history.

No database is required.

---

# Performance Requirements

Expected scale:

* 500+ RFCs
* 1000+ users
* 50+ pods

Use:

* React.memo
* useMemo
* useCallback

Virtualize large dropdown lists.

Avoid full table rerenders.

---

# Accessibility

Support:

* Keyboard-only users
* Screen readers
* ARIA combobox
* ARIA listbox
* Proper focus management

---

# Required Deliverables

## Components

```text
src/components/ResponsibleOwnerCell.tsx
src/components/OwnerTag.tsx
src/components/OwnerLookupDropdown.tsx
```

## Hooks

```text
src/hooks/useOwnerLookup.ts
```

## Utilities

```text
src/utils/areOwnersEqual.ts
src/utils/resolveOwner.ts
src/utils/buildTeamsLink.ts
src/utils/exportModifiedAssignments.ts
src/utils/triggerOwnershipPipeline.ts
```

## Types

```text
src/types/owner.types.ts
```

## Data

```text
data/users.json
data/owners.json
```

## Tests

Implement unit and integration tests covering:

* Display mode
* Edit mode
* Lookup resolution
* Teams links
* Pod search
* Pod expansion
* Unknown users
* Custom owners
* Duplicate prevention
* Save workflow
* Pipeline trigger
* Change detection
* Export generation
* Keyboard navigation
* Accessibility
* Concurrency handling
