# [ISSUE-005] Modal Backdrop Scroll Lock & Outside Click Dismissal

## 📌 Context & Problem Statement
Currently, when a modal overlay is open (such as the Cell Detail Inspector, Connection Form, or Filter/Export Modal):
1. **Background Scroll Leak**: Mouse wheel scroll events `{:scroll, dir, x, y}` continue to pass through to the background DataGrid or Sidebar tree, causing unintended scrolling behind the active modal.
2. **Lack of Outside Click Dismissal**: Clicking outside the modal window (on the dimmed backdrop or UI background) is ignored or misrouted, forcing users to hit `Esc` or navigate to a close button.

---

## 🎯 Proposed Solution

### 1. 🔒 Background Scroll Lock
- In `lib/strata/ui/app.ex` event dispatcher, when `app.modals` stack is non-empty (`modals != []`):
  - Intercept all mouse wheel scroll events (`{:scroll, dir, x, y}`).
  - If the active modal handles scrolling internally (e.g. scrolling long JSON in CellDetailModal), forward the scroll event to the modal handler only.
  - Block all scroll events from reaching underlying background components (`DataGrid`, `Sidebar`, `Editor`).

### 2. 🖱️ Outside Click Dismissal (Backdrop Click to Close)
- Calculate the bounding box rectangle `{modal_x, modal_y, modal_width, modal_height}` of the active top modal in `Renderer.layout`.
- In `handle_mouse(app, {:click, x, y})`, when `app.modals != []`:
  - **Inside Modal Bounds**: Pass the click event to the modal component's internal handler.
  - **Outside Modal Bounds**: Intercept the click event and invoke `pop_modal(app)` to dismiss the active modal cleanly.

---

## ✅ Acceptance Criteria (Definition of Done)

- [ ] **Background Scroll Immunity**: Scrolling mouse wheel while any modal is open does not alter DataGrid scroll position or Sidebar selection.
- [ ] **Backdrop Click Dismissal**: Clicking anywhere outside the active modal's boundary closes the modal.
- [ ] **Modal Input Integrity**: Clicking inside modal form inputs, buttons, or scrollbars remains fully functional without closing the modal.
- [ ] **Test Coverage**: Write unit tests in `test/strata/ui/app_test.exs` verifying:
  - Scroll events are swallowed when `modals != []`.
  - Clicking outside modal bounding box pops the modal from `app.modals`.

---

## 🛠️ Target Files & Modules

- 📄 [`lib/strata/ui/app.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/app.ex)
  - Update `handle_mouse/2` scroll pattern match to lock background scroll when `modals != []`.
  - Add bounding box check for `:click` events to dismiss modal on outside clicks.
- 📄 [`lib/strata/ui/components/cell_detail_modal.ex`](file:///Users/quaywin/Projects_1/strata/lib/strata/ui/components/cell_detail_modal.ex)
  - Provide bounding box coordinates helper `modal_area/2`.
