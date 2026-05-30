# RFC Responsible Owner Management Feature

## Objective

Implement a new **Responsible** column in the existing React Single Page Application hosted on GitLab Pages.

The feature allows users to assign, edit, remove, and manage one or more responsible owners for each RFC directly within the table.

The solution must support:

* Multiple owners per RFC
* User lookup and autocomplete
* Pod-based assignment
* Custom owners
* Unknown users
* Teams hyperlinks
* Change detection
* JSON export of changes
* GitLab Pages static hosting constraints
* Large datasets

No backend API exists.

All data is loaded from static JSON files.

The application must track changes in memory and export modified RFC assignments for future GitLab CI processing.

---

# Core Design Principle

Ownership assignments are free-form.

The lookup database is used only for:

* User discovery
* Autocomplete
* Pod expansion
* Email enrichment
* Teams hyperlink generation

The lookup database must never restrict ownership assignment.

Users must be able to assign:

* Known users
* Unknown users
* Teams
* Vendors
* Groups
* Custom text entries

even when no matching lookup record exists.

---

# Existing Application Context

The application already displays RFC records in a table.

Each row contains a unique RFC number.

Example:

```json
{
  "rfcNumber": "RFC-12345",
  "title": "Implement New Authentication Service"
}
```

RFC Number is the primary key used to associate responsible owners.

---

# Data Sources

## Users Lookup File

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

* email may be empty
* podName may be empty
* podName is optional
* multiple users may belong to the same pod

---

## Owner Assignment File

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
      "name": "Vendor Team"
    }
  ],
  "RFC-54321": [
    {
      "name": "Jane Doe",
      "email": "jane.doe@company.com"
    }
  ]
}
```

Rules:

* RFC may not exist in the file
* RFC may have an empty array
* RFC may have one owner
* RFC may have multiple owners

---

# Application Startup

On application load:

1. Load RFC data
2. Load users.json
3. Load owners.json
4. Merge owners into RFC rows using RFC number

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

* Near end of table
* Before Actions column if one exists

---

# Display Mode

Default state.

## Assigned Owners

Display owners as compact tags.

Example:

```text
[John Smith] [Vendor Team]
```

---

## Teams Hyperlink Logic

If owner contains an email:

```json
{
  "name": "John Smith",
  "email": "john.smith@company.com"
}
```

Generate:

```text
https://teams.microsoft.com/l/chat/0/0?users=<email>
```

Requirements:

* Open new tab
* rel="noopener noreferrer"

---

## Automatic Email Resolution

If owner has no email:

```json
{
  "name": "John Smith"
}
```

Attempt lookup resolution.

Match order:

1. Exact email
2. Exact name
3. Case-insensitive name

If found:

```json
{
  "name": "John Smith",
  "resolvedEmail": "john.smith@company.com"
}
```

Display as hyperlink.

---

## Unknown User Example

```json
{
  "name": "Michael Johnson"
}
```

If no lookup record exists:

* Display as plain text
* No hyperlink
* No validation warning

---

## No Owners

Display:

```text
Unassigned
```

with muted styling.

---

# Entering Edit Mode

Users can enter edit mode by:

* Double-clicking the cell
* Clicking an edit icon
* Pressing Enter while focused

No modal dialogs.

Editing must happen inline inside the table.

---

# Edit Mode

Display owners as removable tags.

Example:

```text
John Smith ×
Vendor Team ×
```

Requirements:

* Remove instantly
* Use stopPropagation()
* Must not trigger Teams links
* Must not exit edit mode

---

# Search and Lookup

Typing:

```text
@john
```

opens a dropdown.

Search against:

* name
* email
* podName

Case-insensitive.

Partial matching supported.

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

Pod matches should appear before individual users.

---

# Pod Assignment

Selecting:

```text
📁 Payments Pod
```

must automatically expand into all pod members.

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

# Duplicate Prevention

Users must not be duplicated.

Deduplicate using:

1. email
2. user id
3. name

---

# Persistence Rule

Do not save pod names.

Persist expanded users only.

Example:

```json
{
  "RFC-12345": [
    {
      "name": "John Smith",
      "email": "john.smith@company.com"
    },
    {
      "name": "Jane Doe",
      "email": "jane.doe@company.com"
    }
  ]
}
```

This ensures RFC ownership remains stable if pod membership changes later.

---

# Custom and Unknown Owner Support

The following are all valid owners:

## Known User

```json
{
  "name": "John Smith",
  "email": "john.smith@company.com"
}
```

## Unknown User

```json
{
  "name": "Michael Johnson"
}
```

## Team

```json
{
  "name": "Architecture Team"
}
```

## Vendor

```json
{
  "name": "External Vendor"
}
```

All must be accepted.

None require a lookup match.

---

# Add Custom Owner

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

No email required.

---

# Keyboard Navigation

Support:

* Arrow Down
* Arrow Up
* Enter
* Escape
* Tab
* Backspace

Backspace removes last tag when input is empty.

---

# Save and Cancel

Provide:

```text
Save
Cancel
```

controls.

---

# Change Detection

Compare:

```typescript
originalOwners
```

against:

```typescript
editedOwners
```

Comparison must include:

* length
* name
* email
* ordering

---

# No Change Scenario

If arrays are identical:

```typescript
{
  hasChanged: false
}
```

Behavior:

* Exit edit mode
* No callback
* No update event

---

# Change Scenario

If modified:

```typescript
onResponsibleChange(
  rfcNumber,
  updatedOwners,
  {
    hasChanged: true
  }
);
```

Update local state.

Exit edit mode.

---

# Cancel Scenario

Cancel must:

* Restore original owners
* Discard edits
* Exit edit mode

---

# Modified RFC Tracking

Maintain a collection containing only changed RFC assignments.

Type:

```typescript
Record<string, ResponsibleOwner[]>
```

Example:

```json
{
  "RFC-12345": [
    {
      "name": "John Smith",
      "email": "john.smith@company.com"
    }
  ],
  "RFC-55555": []
}
```

---

# Export Changes

Provide utility:

```typescript
getModifiedOwnerAssignments()
```

Returns:

```typescript
Record<string, ResponsibleOwner[]>
```

containing only modified RFCs.

---

# Future GitLab CI Workflow

Frontend does not commit files.

Future pipeline will:

1. Read modified assignments
2. Generate updated owners.json
3. Commit changes
4. Push to feature/owners branch
5. Rebuild GitLab Pages

Frontend should remain persistence-agnostic.

---

# Performance Requirements

Expected scale:

* 500+ RFC rows
* 1000+ users
* 50+ pods

Requirements:

Use:

```typescript
React.memo()
useMemo()
useCallback()
```

Avoid full-table rerenders.

Virtualize dropdown when results exceed 50 items.

---

# Accessibility

Support:

* Keyboard-only users
* Screen readers
* ARIA combobox
* ARIA listbox
* Proper focus management

---

# Required Files

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

Create unit tests covering:

* Display mode
* Edit mode
* Teams links
* Email resolution
* Search filtering
* Pod lookup
* Pod expansion
* Duplicate prevention
* Custom owner creation
* Unknown user assignment
* Save behavior
* Cancel behavior
* Change detection
* Export generation
* Keyboard navigation

```
```
