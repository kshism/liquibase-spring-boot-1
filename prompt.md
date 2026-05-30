Act as an expert frontend engineer. Write a reusable component for a data table cell that alternates between a "Display Mode" and an "Edit Mode." It must support tag creation, real-time user-lookup filtering, custom fallback tagging, and intelligent change detection.

Requirements:
1. Default "Display Mode" (Read-Only State):
   - By default, the cell displays selected names as clean inline tags.
   - If a name has an associated email, it must render as a functional hyperlink that opens Microsoft Teams: "https://microsoft.com" (target="_blank").
   - If a name is a custom entry, render it as standard plain text.
   - Double-clicking the cell or clicking an edit button must switch the component into "Edit Mode."

2. "Edit Mode" UI & Keystroke-Driven Lookup:
   - Upon entering Edit Mode, transform the cell into an interactive container enclosing a text input that expands vertically. Selected names should now display as pills with a "×" (cross) icon. Clicking "×" removes the tag (use stopPropagation).
   - Real-Time Filtering: As soon as the user types "@", open a dropdown menu directly below the input. 
   - As the user continues typing characters after the "@", dynamically filter the names from a mock JSON database in real-time on every keystroke (input event). The dropdown must immediately shrink or grow to show only names containing the typed substring.
   - Exclude already-selected names from the lookup dropdown.
   - Fallback Logic: If no match is found for the typed text, show an "Add '[Typed Name]'" option in the dropdown and allow pressing 'Enter' to convert the raw text into a plain text tag.

3. State Tracking & Change Detection on Save:
   - The component must accept an initial array of tags (e.g., initialTags = [{name: "Alice", email: "alice@domain.com"}, {name: "Guest User"}]).
   - Provide a "Save" and "Cancel" mechanism.
   - Upon saving, perform a deep equality check comparing the live tag array against the initial array (checking lengths, values, and order).
   - If no effective modifications occurred, flag it as a "no-change" event, revert to Display Mode, and suppress updates. If a genuine change occurred, fire a callback with `hasChanged: true` and update the Display Mode.
   - Clicking "Cancel" must discard pending edits and restore the initial state.

4. Tech Stack & Integration:
   - Provide complete, self-contained code with HTML, clean CSS, and JavaScript. Include a mock JSON database array (id, name, email) to demonstrate the real-time input filtering, both display states, and the change detection logic.

