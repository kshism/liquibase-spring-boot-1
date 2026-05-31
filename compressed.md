# Responsible Owner Feature

## Overview

Add a new editable table column named **Responsible** to the existing RFC table.

Each row already contains a unique RFC number (numeric identifier).

Ownership data is maintained separately from RFC data and persisted through GitLab CI/CD.

The React application must never directly modify repository files.

---

# Data Sources

## Ownership Data

Location:

```text
data/owners.json
```

Structure:

```typescript
interface ResponsibleOwner {
  name: string;
  email?: string;
}

type OwnersFile = Record<string, ResponsibleOwner[]>;
```

Key = RFC number.

Value = Responsible owners.

This file is the source of truth for ownership assignments.

---

## Lookup Data

Location:

```text
data/users.json
```

Fields:

```typescript
interface LookupUser {
  id?: string;
  name: string;
  email?: string;
  podName?: string;
}
```

Purpose:

* autocomplete
* pod lookup
* email enrichment
* Teams hyperlink generation

The UI is read-only with respect to users.json.

---

# Ownership Rules

Ownership assignment is unrestricted.

Users may assign:

* known users
* unknown users
* teams
* vendors
* contractors
* custom text entries

Lookup data must never restrict ownership assignment.

Unknown owners remain valid ownership entries.

---

# Responsible Column

Add a new column named:

```text
Responsible
```

Display owners as tags.

If email exists or can be uniquely resolved through lookup data:

* render as Teams hyperlink

If email is unavailable:

* render as plain text

Display **Unassigned** when ownership is empty.

---

# Lookup Resolution

Attempt enrichment using:

1. email
2. exact name
3. case-insensitive name

If multiple lookup users match the same name:

* do not auto-resolve
* render as plain text
* require explicit user selection in edit mode

---

# Edit Mode

Enter edit mode via:

* double click
* edit icon
* Enter key

Editing must occur inline inside the table.

No modal dialogs.

Selected owners appear as removable tags.

Support:

* add owner
* remove owner
* replace owner
* custom owner creation
* unknown users
* pod assignment

---

# Search

Typing `@` opens autocomplete.

Search fields:

* name
* email
* podName

Requirements:

* case-insensitive
* partial matching
* exclude already selected owners

---

# Pod Support

Users may select pods.

Selecting a pod expands into all users belonging to that pod.

Deduplicate using:

1. email
2. id
3. name

Duplicate detection must be case-insensitive.

Persist expanded users only.

Do not persist pod names.

Historical ownership must not change if pod membership changes later.

---

# Keyboard Support

Support:

* Arrow Up
* Arrow Down
* Enter
* Escape
* Tab
* Backspace

Backspace removes the last tag when input is empty.

---

# Save / Cancel

## Save

Validate ownership.

Compare against original ownership.

If unchanged:

* exit edit mode
* no persistence action

If changed:

* update local UI immediately
* generate ownership payload
* trigger ownership pipeline

## Cancel

* restore original ownership
* discard edits
* exit edit mode

---

# Change Detection

Compare:

* owner count
* names
* emails
* ordering

Track only modified RFC ownership assignments.

Structure:

```typescript
Record<string, ResponsibleOwner[]>
```

---

# GitLab Integration

Reuse the existing GitLab configuration already loaded from `status.json`.

Extend the existing status model with:

```typescript
ownershipBranch: string;
```

Do not hardcode:

* project id
* project url
* trigger url
* trigger token
* ownership branch

Use the existing GitLab trigger configuration already implemented in the application.

---

# Save Workflow

When ownership changes:

1. Generate payload containing only modified RFCs.
2. Base64 encode payload.
3. Trigger GitLab pipeline.
4. Update local UI immediately.
5. Show success notification.
6. Do not wait for GitLab Pages deployment.

Changes should remain visible immediately in the current browser session.

If trigger fails:

* preserve edits
* show error
* allow retry

---

# Pipeline Trigger

Trigger:

```text
feature/owners
```

Pass:

```text
OWNERSHIP_UPDATE
```

containing the Base64 encoded ownership payload.

Payload contains only modified RFC assignments.

---

# CI/CD Ownership Processing

Runs only on:

```text
feature/owners
```

Stages:

```yaml
preprocess
fetch-data
build
pages
```

## preprocess

Responsibilities:

* read OWNERSHIP_UPDATE
* decode payload
* validate JSON
* validate owner records
* load data/owners.json
* merge updates
* preserve untouched RFCs
* remove duplicates
* keep empty ownership arrays
* sort RFC keys
* save owners.json
* commit changes
* push feature/owners

## Empty Ownership

Keep RFC keys even when ownership is empty.

Example:

```json
"12345": []
```

Do not remove RFC entries.

## Conflict Resolution

Last successful pipeline merge wins.

Updates are applied RFC-by-RFC.

## Loop Prevention

Prevent automation commits from retriggering ownership processing.

Use:

* CI rules
* commit author checks
* commit markers

---

## fetch-data

Download latest:

```text
data/users.json
data/owners.json
```

Expose as build artifacts.

---

## build

Build React application using latest ownership and lookup data.

---

## pages

Publish updated GitLab Pages site.

---

# Auditability

Git history on `feature/owners` acts as the audit trail.

Every ownership change must be recoverable from commit history.

No database is required.

---

# Performance

Target scale:

* 500+ RFC rows
* 1000+ users
* 50+ pods

Use existing project patterns for:

* React.memo
* useMemo
* useCallback
* virtualization

Avoid full table rerenders.

---

# Accessibility

Follow existing project accessibility standards.

Support:

* keyboard-only users
* screen readers
* ARIA combobox
* ARIA listbox
* focus management

---

# Deliverables

Implement:

* ResponsibleOwnerCell
* OwnerTag
* OwnerLookupDropdown
* useOwnerLookup
* areOwnersEqual
* resolveOwner
* buildTeamsLink
* exportModifiedAssignments
* triggerOwnershipPipeline

Include unit and integration tests covering:

* display mode
* edit mode
* lookup resolution
* Teams links
* pod expansion
* unknown users
* duplicate prevention
* change detection
* save workflow
* pipeline trigger
* accessibility
* concurrency handling
