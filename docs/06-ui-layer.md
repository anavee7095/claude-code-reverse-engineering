# Part 6: UI Layer

## Table of Contents

1. [Custom Ink Fork](#1-custom-ink-fork)
2. [Ink Components](#2-ink-components)
3. [Event System](#3-event-system)
4. [Terminal I/O](#4-terminal-io)
5. [REPL Screen](#5-repl-screen)
6. [Component Architecture](#6-component-architecture)
7. [Hook Architecture](#7-hook-architecture)
8. [Keybinding System](#8-keybinding-system)
9. [React Compiler](#9-react-compiler)
10. [Virtual Scrolling](#10-virtual-scrolling)

---

## 1. Custom Ink Fork

### 1.1 Fork Rationale

Claude Code operates a heavily customized fork of the open-source Ink framework. It consists of 96 files, and the rationale for forking is as follows:

- **Browser-style event system**: The original Ink uses a simple EventEmitter-based system, but the fork implements DOM-identical capture/bubble 2-phase dispatch
- **Yoga flexbox WASM native**: Directly integrates `yoga-layout`'s WASM binary to implement complete CSS flexbox layout in the terminal
- **Alt-screen rendering**: Supports alternate screen buffer, mouse tracking, and text selection with a fully custom renderer
- **Performance optimizations**: Dedicated optimizations including double buffering, blit optimization, screen cell pooling, and frame throttling
- **React 19 + Concurrent Mode**: Compatible with `react-reconciler`'s latest API (React 19)

### 1.2 Rendering Pipeline

```
React JSX
  |
  v
[Reconciler] ── react-reconciler(createReconciler)
  |   createInstance() → Create DOMElement
  |   commitUpdate() → Apply props diff
  |   resetAfterCommit() → Trigger onComputeLayout + onRender
  v
[Virtual DOM] ── dom.ts
  |   DOMElement tree (ink-root > ink-box > ink-text > #text)
  |   nodeName: ink-root | ink-box | ink-text | ink-virtual-text | ink-link | ink-raw-ansi
  |   attributes, childNodes, style, yogaNode, scrollTop, etc.
  v
[Layout Engine] ── layout/engine.ts → yoga.ts
  |   Yoga WASM calculateLayout(width)
  |   Compute x, y, width, height for each node
  |   MeasureFunc: ink-text → measureTextNode, ink-raw-ansi → measureRawAnsiNode
  v
[Output] ── output.ts + render-node-to-output.ts
  |   Traverse DOMElement tree
  |   Record text/styles at each node's computed layout coordinates
  |   Apply scroll offset (overflow: scroll)
  |   Viewport culling (skip nodes outside visible area)
  v
[Screen Buffer] ── screen.ts
  |   2D cell array (StylePool + CharPool + HyperlinkPool)
  |   Each cell: grapheme + style index + hyperlink index
  |   Double buffer: frontFrame (current screen) / backFrame (next frame)
  v
[Diff/Blit] ── log-update.ts + render-to-screen.ts
  |   Cell-by-cell comparison of frontFrame vs backFrame
  |   Generate ANSI sequences only for changed cells
  |   Wrapped with BSU(Begin Synchronized Update) / ESU(End)
  v
[Terminal] ── stdout.write()
```

### 1.3 Reconciler Implementation Details

```typescript
// src/ink/reconciler.ts
const reconciler = createReconciler<
  ElementNames,  // 'ink-root' | 'ink-box' | 'ink-text' | ...
  Props,         // Record<string, unknown>
  DOMElement,    // Virtual DOM element
  DOMElement,    // Container type
  TextNode,      // Text node
  // ... React 19 required types
>({
  // --- Instance creation ---
  createInstance(type, props, root, hostContext, fiber) {
    // Check hostContext.isInsideText → disallow ink-box inside ink-text
    // If type is ink-text and already inside text → convert to ink-virtual-text
    const node = createNode(type)
    for (const [key, value] of Object.entries(props)) {
      applyProp(node, key, value)  // style, textStyles, event handlers, attributes
    }
    return node
  },

  createTextInstance(text, root, hostContext) {
    // Error if not hostContext.isInsideText: "Text string must be inside <Text>"
    return createTextNode(text)
  },

  // --- Commit cycle ---
  resetAfterCommit(rootNode) {
    // 1. onComputeLayout() → Yoga calculateLayout
    // 2. onRender() → Throttled render scheduling
    // Profiling instrumentation (COMMIT_LOG environment variable)
  },

  // --- React 19 commitUpdate (no updatePayload) ---
  commitUpdate(node, type, oldProps, newProps) {
    const props = diff(oldProps, newProps)  // shallow diff
    const style = diff(oldProps.style, newProps.style)
    // props diff → setAttribute / setEventHandler / setStyle
    // style diff → applyStyles(yogaNode, style)
  },

  // --- Priority system (React 19) ---
  getCurrentUpdatePriority: () => dispatcher.currentUpdatePriority,
  setCurrentUpdatePriority(p) { dispatcher.currentUpdatePriority = p },
  resolveUpdatePriority: () => dispatcher.resolveEventPriority(),
  resolveEventType: () => dispatcher.currentEvent?.type ?? null,
  resolveEventTimeStamp: () => dispatcher.currentEvent?.timeStamp ?? -1.1,
})
```

### 1.4 Yoga Flexbox Integration

```typescript
// src/ink/layout/node.ts - Layout node interface
export type LayoutNode = {
  // Tree manipulation
  insertChild(child: LayoutNode, index: number): void
  removeChild(child: LayoutNode): void
  getChildCount(): number

  // Layout calculation
  calculateLayout(width?: number, height?: number): void
  setMeasureFunc(fn: LayoutMeasureFunc): void

  // Reading results
  getComputedLeft(): number
  getComputedTop(): number
  getComputedWidth(): number
  getComputedHeight(): number

  // Style setting (full CSS flexbox support)
  setFlexDirection(dir: LayoutFlexDirection): void  // row | column | row-reverse | column-reverse
  setFlexGrow(value: number): void
  setFlexShrink(value: number): void
  setAlignItems(align: LayoutAlign): void    // flex-start | center | flex-end | stretch
  setJustifyContent(justify: LayoutJustify): void  // flex-start | center | space-between | ...
  setOverflow(overflow: LayoutOverflow): void  // visible | hidden | scroll
  setPosition(edge: LayoutEdge, value: number): void
  setMargin(edge: LayoutEdge, value: number): void
  setPadding(edge: LayoutEdge, value: number): void
  setBorder(edge: LayoutEdge, value: number): void
  setGap(gutter: LayoutGutter, value: number): void
}

// src/ink/layout/yoga.ts - Yoga WASM adapter
export class YogaLayoutNode implements LayoutNode {
  readonly yoga: YogaNode  // yoga-layout WASM node

  calculateLayout(width?: number): void {
    this.yoga.calculateLayout(width, undefined, Direction.LTR)
  }

  setMeasureFunc(fn: LayoutMeasureFunc): void {
    this.yoga.setMeasureFunc((w, wMode) => {
      const mode = wMode === MeasureMode.Exactly ? LayoutMeasureMode.Exactly
                 : wMode === MeasureMode.AtMost ? LayoutMeasureMode.AtMost
                 : LayoutMeasureMode.Undefined
      return fn(w, mode)
    })
  }
}
```

### 1.5 Ink Instance (ink.tsx)

The Ink class is the core runtime of the entire TUI application. 1,722 lines (based on source map extraction).

```typescript
// src/ink/ink.tsx
export default class Ink {
  // --- Core state ---
  private rootNode: DOMElement           // Virtual DOM root
  private container: FiberRoot           // React fiber root
  private renderer: Renderer             // Rendering function
  readonly focusManager: FocusManager    // Focus management
  readonly selection: SelectionState     // Text selection state

  // --- Double buffering ---
  private frontFrame: Frame              // Currently displayed frame
  private backFrame: Frame               // Frame to draw next
  private stylePool: StylePool           // Style sharing pool
  private charPool: CharPool             // Character sharing pool
  private hyperlinkPool: HyperlinkPool   // Hyperlink pool

  // --- Alt Screen ---
  private altScreenActive = false
  private altScreenMouseTracking = false
  private prevFrameContaminated = false

  // --- Render scheduling ---
  private scheduleRender: (() => void) & { cancel?: () => void }
  // Throttle: FRAME_INTERVAL_MS (Default ~16ms) leading + trailing
  // Actual render deferred via queueMicrotask (executes after useLayoutEffect)

  constructor(options: Options) {
    // 1. Terminal setup (stdout, stdin, stderr)
    // 2. Screen buffer initialization (double buffer)
    // 3. LogUpdate creation (diff-based output)
    // 4. Render scheduler setup (throttle + microtask)
    // 5. DOM root creation + FocusManager connection
    // 6. Renderer creation
    // 7. onComputeLayout callback (Yoga calculateLayout)
    // 8. React Concurrent Fiber Container creation
    // 9. Signal/resize handler registration
  }

  // Core render loop
  private onRender() {
    // 1. Call renderer() → Generate Screen buffer
    // 2. Apply search highlights
    // 3. Apply text selection overlay
    // 4. Generate diff + terminal.write()
    // 5. Restore cursor position
    // 6. onFrame callback (FPS metrics)
  }
}
```

### 1.6 Double Buffer Screen Structure

```typescript
// src/ink/screen.ts
type Frame = {
  screen: Screen       // 2D cell array
  viewport: { width: number; height: number }
  cursor: { x: number; y: number; visible: boolean }
  scrollHint?: ScrollHint | null
  scrollDrainPending?: boolean
}

// Screen is a cell array + shared pools
class Screen {
  readonly width: number
  readonly height: number
  readonly stylePool: StylePool       // Duplicate style → index mapping
  readonly charPool: CharPool         // Duplicate string → index mapping
  readonly hyperlinkPool: HyperlinkPool  // Hyperlink URL pooling
  // Each cell: packed word[0] = char index + width, word[1] = style index + hyperlink index
}
```

---

## 2. Ink Components

### 2.1 Box (flexbox container)

`<Box>` is Ink's core layout component, equivalent to `<div style="display:flex">` in the browser.

```typescript
// src/ink/components/Box.tsx
type Props = Styles & {  // Styles = full CSS flexbox properties
  ref?: Ref<DOMElement>
  tabIndex?: number        // Tab order (>=0 participates, -1 programmatic only)
  autoFocus?: boolean      // Auto-focus on mount
  onClick?: (event: ClickEvent) => void        // Click (alt-screen only)
  onFocus?: (event: FocusEvent) => void        // Focus gained
  onBlur?: (event: FocusEvent) => void         // Focus lost
  onKeyDown?: (event: KeyboardEvent) => void   // Key input
  onMouseEnter?: () => void                    // Mouse enter
  onMouseLeave?: () => void                    // Mouse leave
}

// Supported Styles properties:
type Styles = {
  // flexbox
  flexDirection?: 'row' | 'column' | 'row-reverse' | 'column-reverse'
  flexGrow?: number
  flexShrink?: number
  flexBasis?: number | string
  flexWrap?: 'nowrap' | 'wrap' | 'wrap-reverse'
  alignItems?: 'flex-start' | 'center' | 'flex-end' | 'stretch'
  alignSelf?: 'auto' | 'flex-start' | 'center' | 'flex-end' | 'stretch'
  justifyContent?: 'flex-start' | 'flex-end' | 'space-between' | 'space-around' | 'space-evenly' | 'center'

  // Size
  width?: number | string
  height?: number | string
  minWidth?: number | string
  minHeight?: number | string
  maxWidth?: number | string
  maxHeight?: number | string

  // Margin/padding/border
  margin?: number  // + marginX, marginY, marginLeft, ...
  padding?: number // + paddingX, paddingY, paddingLeft, ...
  borderStyle?: 'single' | 'double' | 'round' | 'bold' | ...

  // Position
  position?: 'absolute' | 'relative'
  top?: number | string
  left?: number | string

  // Overflow
  overflow?: 'visible' | 'hidden' | 'scroll'
  overflowX?: 'visible' | 'hidden' | 'scroll'
  overflowY?: 'visible' | 'hidden' | 'scroll'  // All three properties support scroll

  // Text
  textWrap?: 'wrap' | 'truncate' | 'truncate-end' | 'truncate-middle' | ...

  // Gap
  columnGap?: number
  rowGap?: number

  // Selection prevention
  noSelect?: boolean | 'from-left-edge'
}
```

**Internal implementation**: When the Reconciler calls `createInstance('ink-box', props)`, `createNode('ink-box')` allocates a Yoga node, and `applyStyles(yogaNode, style)` converts CSS properties to Yoga properties.

### 2.2 Text (styled text)

```typescript
// src/ink/components/Text.tsx
type Props = {
  color?: Color              // Text color (rgb, hex, ansi256, ansi name)
  backgroundColor?: Color    // Background color
  bold?: boolean             // Bold (mutually exclusive with dim)
  dim?: boolean              // Dim (mutually exclusive with bold)
  italic?: boolean
  underline?: boolean
  strikethrough?: boolean
  inverse?: boolean          // Foreground/background inversion
  wrap?: Styles['textWrap']  // Text wrapping mode
}
```

- **MeasureFunc**: `ink-text` nodes register a measureFunc with Yoga that squashes internal text and calculates width/height via `measureText()`
- **textWrap options** (8): `wrap` (default), `wrap-trim`, `end`, `middle`, `truncate`, `truncate-end`, `truncate-middle`, `truncate-start`
- **Bold/Dim mutual exclusion**: Prevented from simultaneous use via TypeScript union types

### 2.3 Button (interactive button)

```typescript
// src/ink/components/Button.tsx
type ButtonState = { focused: boolean; hovered: boolean; active: boolean }

type Props = Styles & {
  onAction: () => void              // Activated via Enter, Space, or click
  tabIndex?: number                 // Default 0 (participates in tab order)
  autoFocus?: boolean
  children: ((state: ButtonState) => ReactNode) | ReactNode  // Render prop support
}
```

- Calls `onAction` on Enter/Space key input
- Click events also connected to onAction
- If `children` is a function, passes `ButtonState` as argument for state-based styling
- Active state provides visual feedback via a 200ms timer

### 2.4 ScrollBox (scroll container)

```typescript
// src/ink/components/ScrollBox.tsx
type ScrollBoxHandle = {
  scrollTo(y: number): void
  scrollBy(dy: number): void
  scrollToElement(el: DOMElement, offset?: number): void  // Render-time position calculation
  scrollToBottom(): void
  getScrollTop(): number
  getScrollHeight(): number
  getFreshScrollHeight(): number  // Direct Yoga call (latest value)
  getViewportHeight(): number
  isSticky(): boolean             // Bottom-fixed state
  subscribe(listener: () => void): () => void
  setClampBounds(min?: number, max?: number): void  // Virtual scroll clamp
}

type ScrollBoxProps = Styles & {
  ref?: Ref<ScrollBoxHandle>
  stickyScroll?: boolean    // When true, auto-fixes to bottom as content grows
}
```

**Key design**:
- Directly modifies the DOM node's `scrollTop` bypassing React state (performance)
- Directly calls `scheduleRender` to avoid Reconciler overhead
- `pendingScrollDelta`: Limits maximum movement per frame during fast scrolling (smooth scroll)
- `scrollAnchor`: Element-based scrolling (reads `yogaNode.getComputedTop()` at render time)

### 2.5 Link (hyperlink)

```typescript
// src/ink/components/Link.tsx
type Props = {
  url: string
  children?: ReactNode
  fallback?: ReactNode  // For terminals that don't support hyperlinks
}
```

- Uses OSC 8 sequences when terminal supports hyperlinks (`supportsHyperlinks()`)
- Shows fallback or URL text when unsupported

### 2.6 RawAnsi (ANSI bypass)

```typescript
// src/ink/components/RawAnsi.tsx
type Props = {
  lines: string[]   // Array of lines already containing ANSI escapes
  width: number     // Column width the producer wrapped at
}
```

- Directly injects ANSI output already generated by external renderers (e.g., ColorDiff NAPI) without going through the React tree
- Registers a fixed-size (width x lines.length) measureFunc with Yoga
- Completely skips the `<Ansi>` component's parse/re-serialize roundtrip (performance)

### 2.7 NoSelect (selection prevention)

```typescript
// src/ink/components/NoSelect.tsx
type Props = BoxProps & {
  fromLeftEdge?: boolean  // Excludes from column 0 to the right edge of this box
}
```

- Skips cells in this region during text selection (gutters, line numbers, diff +/- symbols)
- `fromLeftEdge=true`: Excludes the entire left margin from gutters inside indented containers

---

## 3. Event System

### 3.1 Event Type Hierarchy

```
Event (base)
  |
  +-- TerminalEvent (DOM-style propagation)
  |     |
  |     +-- KeyboardEvent
  |     +-- FocusEvent
  |     +-- PasteEvent
  |     +-- ResizeEvent
  |
  +-- ClickEvent (legacy, directly inherits Event)
  +-- InputEvent (legacy, directly inherits Event)
```

### 3.2 TerminalEvent (base class)

```typescript
// src/ink/events/terminal-event.ts
class TerminalEvent extends Event {
  readonly type: string          // 'keydown', 'focus', 'blur', 'paste', 'resize'
  readonly timeStamp: number     // performance.now()
  readonly bubbles: boolean      // Whether it bubbles
  readonly cancelable: boolean   // Whether preventDefault is possible

  target: EventTarget | null
  currentTarget: EventTarget | null
  eventPhase: 'none' | 'capturing' | 'at_target' | 'bubbling'

  stopPropagation(): void
  stopImmediatePropagation(): void
  preventDefault(): void

  // Subclass hook: per-node setup before each handler execution
  _prepareForTarget(target: EventTarget): void
}

type EventTarget = {
  parentNode: EventTarget | undefined
  _eventHandlers?: Record<string, unknown>
}
```

### 3.3 Individual Event Types

| Event | Type String | bubbles | Description |
|--------|-----------|---------|------|
| `KeyboardEvent` | `keydown` | true | Key input. `key`, `ctrl`, `shift`, `meta`, `superKey`, `fn` |
| `FocusEvent` | `focus`/`blur` | true | Focus change. `relatedTarget` (previous/next focus target) |
| `ClickEvent` | `click` | true* | Mouse click. `col`, `row`, `localCol`, `localRow`, `cellIsBlank` |
| `InputEvent` | - | - | Key input → Key + input parsing (legacy, EventEmitter-based) |
| `PasteEvent` | `paste` | true | Paste data |
| `ResizeEvent` | `resize` | true | Terminal size change |

### 3.4 Dispatcher

```typescript
// src/ink/events/dispatcher.ts
class Dispatcher {
  currentEvent: TerminalEvent | null = null
  currentUpdatePriority: number = DefaultEventPriority
  discreteUpdates: DiscreteUpdates | null = null  // Injected from reconciler

  // Event dispatch (capture + bubble)
  dispatch(target: EventTarget, event: TerminalEvent): boolean {
    event._setTarget(target)
    const listeners = collectListeners(target, event)  // 2-phase collection
    processDispatchQueue(listeners, event)              // Sequential execution
    return !event.defaultPrevented
  }

  // Synchronous priority dispatch (keyboard, click, focus, paste)
  dispatchDiscrete(target, event): boolean

  // Continuous priority dispatch (resize, scroll, mouse move)
  dispatchContinuous(target, event): boolean

  // React reconciler priority integration
  resolveEventPriority(): number
}
```

**Listener collection algorithm** (identical to react-dom):

```
Traverse tree from target → root:
1. At each node, capture handler → insert at front of list (unshift)
2. At each node, bubble handler → append to end of list (push)

Result: [root-cap, ..., parent-cap, target-cap, target-bub, parent-bub, ..., root-bub]
```

**Priority mapping**:

| Event | React Priority |
|--------|--------------|
| keydown, keyup, click, focus, blur, paste | `DiscreteEventPriority` (synchronous) |
| resize, scroll, mousemove | `ContinuousEventPriority` (batched) |
| Other | `DefaultEventPriority` |

### 3.5 Event Handler Props

```typescript
// src/ink/events/event-handlers.ts
type EventHandlerProps = {
  onKeyDown?: (event: KeyboardEvent) => void
  onKeyDownCapture?: (event: KeyboardEvent) => void
  onFocus?: (event: FocusEvent) => void
  onFocusCapture?: (event: FocusEvent) => void
  onBlur?: (event: FocusEvent) => void
  onBlurCapture?: (event: FocusEvent) => void
  onPaste?: (event: PasteEvent) => void
  onPasteCapture?: (event: PasteEvent) => void
  onResize?: (event: ResizeEvent) => void
  onClick?: (event: ClickEvent) => void
  onMouseEnter?: () => void  // Does not bubble (same as DOM mouseenter)
  onMouseLeave?: () => void
}

// Event type → handler prop reverse mapping (for O(1) lookup)
const HANDLER_FOR_EVENT = {
  keydown: { bubble: 'onKeyDown', capture: 'onKeyDownCapture' },
  focus:   { bubble: 'onFocus',   capture: 'onFocusCapture' },
  blur:    { bubble: 'onBlur',    capture: 'onBlurCapture' },
  paste:   { bubble: 'onPaste',   capture: 'onPasteCapture' },
  resize:  { bubble: 'onResize' },
  click:   { bubble: 'onClick' },
}
```

### 3.6 EventEmitter (legacy)

```typescript
// src/ink/events/emitter.ts
class EventEmitter extends NodeEventEmitter {
  constructor() {
    super()
    this.setMaxListeners(0)  // Allow React multiple useInput
  }

  override emit(type, ...args) {
    // If Event instance, respects stopImmediatePropagation()
    const ccEvent = args[0] instanceof Event ? args[0] : null
    for (const listener of this.rawListeners(type)) {
      listener.apply(this, args)
      if (ccEvent?.didStopImmediatePropagation()) break
    }
  }
}
```

### 3.7 Event Flow Diagram

```
stdin data received
  │
  ├─ parseKeypress() → ParsedKey[]
  │    │
  │    ├─ InputEvent created → EventEmitter.emit('input', event)
  │    │                      → useInput hooks subscribe
  │    │
  │    ├─ KeyboardEvent created → dispatcher.dispatchDiscrete(focusedNode, event)
  │    │                        → capture phase (root → target)
  │    │                        → bubble phase (target → root)
  │    │
  │    ├─ Mouse events (SGR encoding)
  │    │    ├─ Click → dispatchClick() → hit-test → ClickEvent
  │    │    ├─ Wheel → scrollBy()
  │    │    └─ Drag → selection update
  │    │
  │    └─ Paste (bracketed paste)
  │         └─ PasteEvent → dispatcher.dispatchDiscrete()
  │
  └─ Terminal focus (DEC mode 1004)
       └─ TerminalFocusEvent → useTerminalFocus hook
```

---

## 4. Terminal I/O

### 4.1 Architecture Overview

The `src/ink/termio/` directory handles parsing and generation of ANSI escape sequences. Inspired by the action-based design of the Ghostty terminal emulator.

```
stdin byte stream
  │
  ├─ [tokenize.ts] Tokenization: text | sequence
  │    └─ State machine: ground → escape → csi/osc/dcs/apc/ss3
  │
  ├─ [parser.ts] Semantic parsing: Token[] → Action[]
  │    ├─ CSI sequences → cursor/erase/scroll/mode
  │    ├─ OSC sequences → title/hyperlink/tab status
  │    ├─ SGR parameters → TextStyle update
  │    └─ Text → Grapheme segmentation (CJK/emoji width)
  │
  └─ [sgr.ts] SGR parsing: color + style attributes
```

### 4.2 Tokenizer

```typescript
// src/ink/termio/tokenize.ts
type Token = { type: 'text'; value: string }
           | { type: 'sequence'; value: string }

type Tokenizer = {
  feed(input: string): Token[]   // Streaming input
  flush(): Token[]               // Force output incomplete sequences
  reset(): void
  buffer(): string               // Current buffer content
}

// State machine states
type State = 'ground' | 'escape' | 'escapeIntermediate'
           | 'csi' | 'ss3' | 'osc' | 'dcs' | 'apc'

// Options
type TokenizerOptions = {
  x10Mouse?: boolean  // Treat CSI M as mouse event (stdin only)
}
```

### 4.3 ANSI Constants and Sequence Types

```typescript
// src/ink/termio/ansi.ts - C0 control characters
const C0 = {
  NUL: 0x00, SOH: 0x01, BEL: 0x07, BS: 0x08,
  HT: 0x09,  LF: 0x0a,  CR: 0x0d,  ESC: 0x1b,
  DEL: 0x7f,
  // ... 32 C0 characters
}

// Escape sequence type identifiers
const ESC_TYPE = {
  CSI: 0x5b,  // [ - Control Sequence Introducer
  OSC: 0x5d,  // ] - Operating System Command
  DCS: 0x50,  // P - Device Control String
  APC: 0x5f,  // _ - Application Program Command
  SS3: 0x4f,  // O - Single Shift 3
}

// src/ink/termio/csi.ts - CSI commands
const CSI = {
  // Cursor movement
  CUU: 0x41,  // A - Up
  CUD: 0x42,  // B - Down
  CUF: 0x43,  // C - Forward
  CUB: 0x44,  // D - Backward
  CUP: 0x48,  // H - Position
  // Erase
  ED:  0x4a,  // J - Erase display
  EL:  0x4b,  // K - Erase line
  // Insert/delete
  IL:  0x4c,  // L - Insert line
  DL:  0x4d,  // M - Delete line
  // Scroll
  SU:  0x53,  // S - Scroll up
  SD:  0x54,  // T - Scroll down
  // Mode (DEC private)
  DECSET: 0x68,  // h
  DECRST: 0x6c,  // l
}
```

### 4.4 SGR (Select Graphic Rendition) Parser

```typescript
// src/ink/termio/sgr.ts
// SGR parameters → TextStyle conversion

type TextStyle = {
  bold: boolean
  dim: boolean
  italic: boolean
  underline: UnderlineStyle  // 'none'|'single'|'double'|'curly'|'dotted'|'dashed'
  blink: boolean
  inverse: boolean
  hidden: boolean
  strikethrough: boolean
  overline: boolean
  fg: Color                  // Foreground color
  bg: Color                  // Background color
  underlineColor: Color      // Underline color
}

type Color =
  | { type: 'named'; name: NamedColor }     // 16-color palette
  | { type: 'indexed'; index: number }       // 256-color
  | { type: 'rgb'; r: number; g: number; b: number }  // TrueColor
  | { type: 'default' }

// Parsing: supports both semicolon (;) and colon (:) delimiters
// Extended colors: SGR 38;2;r;g;b (RGB), SGR 38;5;n (256-color)
// Underline color: SGR 58;2;r;g;b
```

### 4.5 Semantic Actions

```typescript
// src/ink/termio/types.ts - Parser output types
type Action =
  | { type: 'text'; graphemes: Grapheme[]; style: TextStyle }
  | { type: 'cursor'; action: CursorAction }
  | { type: 'erase'; action: EraseAction }
  | { type: 'scroll'; action: ScrollAction }
  | { type: 'mode'; action: ModeAction }
  | { type: 'link'; action: LinkAction }
  | { type: 'title'; action: TitleAction }
  | { type: 'tabStatus'; action: TabStatusAction }
  | { type: 'sgr'; params: string }
  | { type: 'bell' }
  | { type: 'reset' }
  | { type: 'unknown'; sequence: string }

// Mode actions
type ModeAction =
  | { type: 'alternateScreen'; enabled: boolean }   // DEC 1049
  | { type: 'bracketedPaste'; enabled: boolean }     // DEC 2004
  | { type: 'mouseTracking'; mode: 'off'|'normal'|'button'|'any' }  // DEC 1000/1002/1003
  | { type: 'focusEvents'; enabled: boolean }        // DEC 1004

// Grapheme cluster (visual character unit)
type Grapheme = {
  value: string
  width: 1 | 2  // Terminal column width (CJK/emoji = 2)
}
```

### 4.6 Grapheme Width Calculation

```typescript
// src/ink/termio/parser.ts
function graphemeWidth(grapheme: string): 1 | 2 {
  if (hasMultipleCodepoints(grapheme)) return 2  // Composite emoji
  const codePoint = grapheme.codePointAt(0)
  if (isEmoji(codePoint)) return 2
  if (isEastAsianWide(codePoint)) return 2  // CJK, Hangul
  return 1
}

// Intl.Segmenter-based grapheme segmentation
function* segmentGraphemes(str: string): Generator<Grapheme> {
  for (const { segment } of getGraphemeSegmenter().segment(str)) {
    yield { value: segment, width: graphemeWidth(segment) }
  }
}
```

---

## 5. REPL Screen

### 5.1 Overview

`src/screens/REPL.tsx` is the 5,005-line main screen component that constitutes Claude Code's entire interactive interface.

### 5.2 Provider Tree

The provider hierarchy is divided between **App.tsx** (outer wrapper) and **REPL.tsx** (inner interactive UI).

```
// === App.tsx hierarchy (wraps outside REPL.tsx) ===
<FpsMetricsProvider>          // FPS metrics context
  <StatsProvider>             // Session statistics context
    <AppStateProvider>        // Global AppState context (store-based)
      <MCPConnectionManager>  // MCP server connection management (includes IDE MCP auto-connect)
        <REPL ... />          // Interactive UI entry point

// === REPL.tsx hierarchy (inner interactive UI) ===
        <KeybindingSetup>                    // Keybinding context initialization
          <AlternateScreen mouseTracking>    // Alt-screen + mouse
            <TerminalWriteProvider>          // Direct terminal write
              <PromptOverlayProvider>        // Command overlay
                <FullscreenLayout            // Main layout
                  scrollable={<Messages />}  // Scrollable message list
                  bottom={<PromptInput />}   // Bottom-fixed input
                  overlay={<PermissionRequest />}
                  modal={<Tabs />}           // Modal dialog
                />
              </PromptOverlayProvider>
            </TerminalWriteProvider>
          </AlternateScreen>
        </KeybindingSetup>
      </MCPConnectionManager>
    </AppStateProvider>
  </StatsProvider>
</FpsMetricsProvider>
```

**MCPConnectionManager**: Handles IDE MCP auto-connection (`autoConnectIdeFlag`) in App.tsx.
Passes connection state (`mcpClients`, `dynamicMcpConfig`) as props to REPL.

### 5.3 REPL Function Signature

```typescript
export function REPL({
  commands: initialCommands,
  debug,
  initialTools,
  initialMessages,
  pendingHookMessages,
  initialFileHistorySnapshots,
  initialContentReplacements,
  initialAgentName,
  initialAgentColor,
  mcpClients: initialMcpClients,
  dynamicMcpConfig: initialDynamicMcpConfig,
  autoConnectIdeFlag,
  strictMcpConfig,
  systemPrompt: customSystemPrompt,
  appendSystemPrompt,
  onBeforeQuery,
  onTurnComplete,
  disabled,
  mainThreadAgentDefinition: initialMainThreadAgentDefinition,
  disableSlashCommands,
  taskListId,
  remoteSessionConfig,
  directConnectConfig,
  sshSession,
  thinkingConfig,
}: Props): React.ReactNode
```

### 5.4 Core Hook Integration (100+ hooks)

Major hook categories used in REPL:

**State management:**
- `useAppState(selector)` - Global app state access (20+ calls)
- `useSetAppState()` - State updates
- `useCommandQueue()` - Command queue
- `useState()` - Local state (agent definition, messages, tools, etc.)

**API/session:**
- `useRemoteSession()` - Remote session management
- `useDirectConnect()` - Direct connection management
- `useSSHSession()` - SSH session
- `useApiKeyVerification()` - API key verification
- `useAssistantHistory()` - Conversation history

**Input/interaction:**
- `useInput()` - Key input handling (legacy)
- `useSearchInput()` - Search input
- `useTextInput()` - Text editing
- `useArrowKeyHistory()` - Arrow key history navigation

**Keybindings:**
- `KeybindingSetup` - Keybinding context setup
- `GlobalKeybindingHandlers` - Global keybindings
- `CommandKeybindingHandlers` - Command keybindings
- `CancelRequestHandler` - Cancel request handler
- `useShortcutDisplay()` - Shortcut display

**UI/rendering:**
- `useTerminalSize()` - Terminal size
- `useTerminalFocus()` - Terminal focus (DEC 1004)
- `useTerminalTitle()` - Terminal title (OSC 2)
- `useTabStatus()` - Tab status display
- `useSearchHighlight()` - Search highlighting
- `useFpsMetrics()` - FPS metrics
- `useAfterFirstRender()` - Post-initial-render work

**Notifications:**
- `useNotifications()` - Notification system
- `useTerminalNotification()` - Terminal notifications
- `useCostSummary()` - Cost summary

**Logging/analytics:**
- `useLogMessages()` - Log messages
- `useIdeLogging()` - IDE logging
- `useReplBridge()` - REPL bridge

### 5.5 Message Rendering

```typescript
// Message list is virtualized via VirtualMessageList
<VirtualMessageList
  messages={renderableMessages}
  scrollRef={scrollRef}
  columns={columns}
  itemKey={(msg) => msg.uuid}
  renderItem={(msg, index) => (
    <Message
      message={msg}
      lookups={lookups}
      tools={tools}
      commands={commands}
      verbose={verbose}
      inProgressToolUseIDs={inProgressToolUseIDs}
      progressMessagesForMessage={progressMessages}
      shouldAnimate={shouldAnimate}
      isTranscriptMode={isTranscriptMode}
      // ... additional props
    />
  )}
  trackStickyPrompt
  jumpRef={jumpRef}
/>
```

### 5.6 Tool Execution Display

REPL displays tool execution state as follows:

- **SpinnerWithVerb**: Displayed during tool execution (verb-based status message)
- **BriefIdleStatus**: Idle state display
- **TeammateSpinnerTree**: Teammate agent status tree

### 5.7 Permission Dialog

```typescript
// Tool use permission request
<PermissionRequest
  toolUseConfirm={toolUseConfirm}
  onAllow={handleAllow}
  onDeny={handleDeny}
  onAlwaysAllow={handleAlwaysAllow}
/>

// Cost threshold dialog
<CostThresholdDialog
  cost={cost}
  threshold={threshold}
  onContinue={handleContinue}
  onStop={handleStop}
/>

// Idle return dialog
<IdleReturnDialog
  idleTime={idleTime}
  onContinue={handleContinue}
/>
```

---

## 6. Component Architecture

### 6.1 Overall File Structure (346 files, .tsx only)

```
src/components/
├── App.tsx                           # Top-level provider wrapper
├── Message.tsx                       # Message type dispatch
├── Messages.tsx                      # Message list management
├── VirtualMessageList.tsx            # Virtual scroll list
├── FullscreenLayout.tsx              # Fullscreen layout (ScrollBox + bottom)
├── OffscreenFreeze.tsx               # Offscreen render freeze
│
├── messages/                         # Per-message-type components
│   ├── AssistantTextMessage.tsx       # AI text response
│   ├── AssistantThinkingMessage.tsx   # Thinking process display
│   ├── AssistantToolUseMessage.tsx    # Tool use message
│   ├── UserTextMessage.tsx           # User text
│   ├── UserImageMessage.tsx          # User image
│   ├── UserToolResultMessage/        # Tool execution result
│   ├── SystemTextMessage.tsx         # System message
│   ├── GroupedToolUseContent.tsx      # Grouped tool use
│   ├── CollapsedReadSearchContent.tsx # Collapsed read/search
│   └── CompactBoundaryMessage.tsx    # Compact boundary
│
├── permissions/                      # Permission request dialogs
│   ├── PermissionRequest.tsx         # Permission request main
│   ├── WorkerPendingPermission.tsx   # Worker pending permission
│   └── ...
│
├── PromptInput/                      # Prompt input (21 files)
│   ├── PromptInput.tsx               # Main input component
│   ├── PromptInputFooter.tsx         # Bottom status display
│   ├── PromptInputHelpMenu.tsx       # Help menu
│   ├── HistorySearchInput.tsx        # History search
│   ├── ShimmeredInput.tsx            # Shimmer effect input
│   ├── VoiceIndicator.tsx            # Voice indicator
│   ├── inputModes.ts                 # Input modes (plan/auto/manual)
│   └── ...
│
├── design-system/                    # Design system (16 files)
│   ├── ThemeProvider.tsx             # Theme provider
│   ├── ThemedBox.tsx                 # Themed Box
│   ├── ThemedText.tsx                # Themed Text
│   ├── Dialog.tsx                    # Modal dialog
│   ├── Pane.tsx                      # Panel container
│   ├── Tabs.tsx                      # Tab component
│   ├── FuzzyPicker.tsx               # Fuzzy search picker
│   ├── ListItem.tsx                  # List item
│   ├── ProgressBar.tsx               # Progress bar
│   ├── Divider.tsx                   # Divider
│   ├── Byline.tsx                    # Byline
│   ├── KeyboardShortcutHint.tsx      # Keyboard shortcut hint
│   ├── StatusIcon.tsx                # Status icon
│   ├── LoadingState.tsx              # Loading state
│   ├── Ratchet.tsx                   # Ratchet (value only increases)
│   └── color.ts                      # Color utilities
│
├── Spinner/                          # Spinner animations (12 files)
│   ├── index.ts                      # SpinnerWithVerb, BriefIdleStatus
│   ├── SpinnerGlyph.tsx              # Glyph character animation
│   ├── SpinnerAnimationRow.tsx       # Animation row
│   ├── ShimmerChar.tsx               # Shimmer character effect
│   ├── FlashingChar.tsx              # Flashing character
│   ├── GlimmerMessage.tsx            # Glimmer message
│   ├── TeammateSpinnerLine.tsx       # Teammate spinner line
│   ├── TeammateSpinnerTree.tsx       # Teammate spinner tree
│   ├── useShimmerAnimation.ts        # Shimmer animation hook
│   └── useStalledAnimation.ts        # Stalled animation hook
│
├── mcp/                              # MCP-related components
│   ├── ElicitationDialog.tsx         # Elicitation dialog
│   └── ...
│
├── hooks/                            # Component-level hook wrappers
│   └── PromptDialog.tsx              # Prompt dialog
│
├── shell/                            # Shell output related
│   └── ExpandShellOutputContext.tsx   # Shell output expansion context
│
└── ... (other utility components)
```

### 6.2 Message Type Dispatch

```typescript
// src/components/Message.tsx
function MessageImpl({ message, ... }: Props) {
  const { columns } = useTerminalSize()

  // Dispatch based on message role + content block type
  switch (message.type) {
    case 'user':
      // Iterate content blocks
      for (const block of message.content) {
        if (block.type === 'text')        → <UserTextMessage />
        if (block.type === 'image')       → <UserImageMessage />
        if (block.type === 'tool_result') → <UserToolResultMessage />
      }
      break

    case 'assistant':
      for (const block of message.content) {
        if (block.type === 'text')        → <AssistantTextMessage />
        if (block.type === 'thinking')    → <AssistantThinkingMessage />
        if (block.type === 'tool_use')    → <AssistantToolUseMessage />
      }
      break

    case 'system':       → <SystemTextMessage />
    case 'attachment':   → <AttachmentMessage />
    case 'grouped':      → <GroupedToolUseContent />
    case 'collapsed':    → <CollapsedReadSearchContent />
  }
}

// Wrapped with OffscreenFreeze to freeze messages outside the viewport
export const Message = React.memo(MessageImpl)
```

### 6.3 Design System

**ThemeProvider**: Provides global theme (color palette, theme keys) via Context

```typescript
// Theme structure (simplified)
type Theme = {
  permission: string      // Permission request color
  primary: string         // Primary color
  secondary: string       // Secondary color
  success: string         // Success
  warning: string         // Warning
  error: string           // Error
  text: string            // Default text
  dimText: string         // Dim text
  border: string          // Border
  // ... additional theme keys
}
```

**Dialog**: Modal dialog framework

```typescript
function Dialog({
  title,
  subtitle,
  children,
  onCancel,
  color = 'permission',
  hideInputGuide,
  hideBorder,
  inputGuide,
  isCancelActive = true,
}: DialogProps)

// Built-in keybindings:
// - confirm:no (Esc/n) → onCancel
// - app:interrupt/exit (Ctrl-C/D) → exit handling
// - isCancelActive=false → Prevents key conflicts during text field editing
```

**Pane**: Bordered panel container
**Tabs**: Tab switching UI (Tab/Shift+Tab navigation)
**FuzzyPicker**: Fuzzy search-based selection UI

### 6.4 Component Hierarchy Diagram

```
App
└── REPL
    ├── KeybindingSetup
    │   └── AlternateScreen
    │       └── FullscreenLayout
    │           ├── [scrollable] Messages
    │           │   └── VirtualMessageList
    │           │       ├── StickyTracker
    │           │       ├── VirtualScrollSpacer (top)
    │           │       ├── Message[] (visible range)
    │           │       │   ├── UserTextMessage
    │           │       │   ├── AssistantTextMessage
    │           │       │   ├── AssistantToolUseMessage
    │           │       │   │   └── UserToolResultMessage
    │           │       │   │       ├── BashToolResult
    │           │       │   │       ├── EditToolResult
    │           │       │   │       ├── ReadToolResult
    │           │       │   │       └── ...
    │           │       │   ├── AssistantThinkingMessage
    │           │       │   └── SystemTextMessage
    │           │       └── VirtualScrollSpacer (bottom)
    │           │
    │           ├── [bottom]
    │           │   ├── SpinnerWithVerb / BriefIdleStatus
    │           │   ├── PromptInput
    │           │   │   ├── ShimmeredInput (text editing)
    │           │   │   ├── PromptInputModeIndicator
    │           │   │   ├── PromptInputFooter
    │           │   │   │   ├── PromptInputFooterLeftSide
    │           │   │   │   └── PromptInputFooterSuggestions
    │           │   │   └── PromptInputHelpMenu (?)
    │           │   └── PromptInputQueuedCommands
    │           │
    │           ├── [overlay] PermissionRequest
    │           │   └── Dialog
    │           │       └── Pane
    │           │
    │           └── [modal]
    │               ├── Tabs (Ctrl-O transcript)
    │               ├── CostThresholdDialog
    │               ├── IdleReturnDialog
    │               ├── ElicitationDialog
    │               ├── SkillImprovementSurvey
    │               └── MessageSelector
    │
    ├── GlobalKeybindingHandlers
    ├── CommandKeybindingHandlers
    └── CancelRequestHandler
```

---

## 7. Hook Architecture

### 7.1 Hook Classification (104 hooks)

**Ink built-in hooks (12)**:

| Hook | File | Purpose |
|----|------|------|
| `useInput` | `use-input.ts` | Key input handling (legacy EventEmitter) |
| `useStdin` | `use-stdin.ts` | stdin access + raw mode |
| `useApp` | `use-app.ts` | Ink app instance |
| `useAnimationFrame` | `use-animation-frame.ts` | Frame-based animation |
| `useInterval` | `use-interval.ts` | Interval timer |
| `useTerminalViewport` | `use-terminal-viewport.ts` | Viewport size |
| `useTerminalFocus` | `use-terminal-focus.ts` | DEC 1004 focus events |
| `useTerminalTitle` | `use-terminal-title.ts` | OSC 2 title setting |
| `useTabStatus` | `use-tab-status.ts` | OSC 21337 tab status |
| `useDeclaredCursor` | `use-declared-cursor.ts` | Native cursor position |
| `useSelection` | `use-selection.ts` | Text selection state |
| `useSearchHighlight` | `use-search-highlight.ts` | Search highlighting |

**Application hooks (92, `src/hooks/`)**:

By major category:

| Category | Hook | Description |
|---------|-----|------|
| **Text input** | `useTextInput` | Full text editing logic (cursor, killing, history, paste) |
| **Tool permission** | `useCanUseTool` | Tool usability determination |
| | `useToolPermission` | Per-tool permission settings |
| **Notifications (16+)** | `useNotifications` | Notification system |
| | `useTerminalNotification` | Terminal bell/notification |
| | `useChromeExtensionNotification` | Chrome extension notification |
| | `useClaudeCodeHintRecommendation` | Hint recommendation |
| **Keybindings** | `useKeybinding` | Action-based keybinding registration |
| | `useShortcutDisplay` | Shortcut display text |
| | `useGlobalKeybindings` | Global keybinding handler |
| | `useCommandKeybindings` | Command keybinding handler |
| **Session** | `useRemoteSession` | Remote session |
| | `useDirectConnect` | Direct connection |
| | `useSSHSession` | SSH session |
| **History** | `useAssistantHistory` | Assistant conversation history |
| | `useArrowKeyHistory` | Arrow key history navigation |
| | `useHistorySearch` | Ctrl+R history search |
| **State** | `useAppState` | Global state read |
| | `useSetAppState` | Global state write |
| | `useCommandQueue` | Command queue management |
| **Virtual scroll** | `useVirtualScroll` | Virtual scroll logic |
| **Other** | `useCostSummary` | Cost tracking |
| | `useFpsMetrics` | FPS metrics |
| | `useAfterFirstRender` | Post-initial-render work |
| | `useBlink` | Blink effect |
| | `useDoublePress` | Double press detection |
| | `useElapsedTime` | Elapsed time |

### 7.2 useTextInput Details

```typescript
// src/hooks/useTextInput.ts
type UseTextInputProps = {
  value: string
  onChange: (value: string) => void
  onSubmit?: (value: string) => void
  onExit?: () => void
  onHistoryUp?: () => void
  onHistoryDown?: () => void
  focus?: boolean
  multiline?: boolean
  cursorChar: string
  columns: number
  maxVisibleLines?: number
  externalOffset: number
  onOffsetChange: (offset: number) => void
  inlineGhostText?: InlineGhostText
  inputFilter?: (input: string, key: Key) => string
  onImagePaste?: (base64, mediaType, filename, dimensions, sourcePath) => void
}

// Return: TextInputState
type TextInputState = {
  renderedText: string   // Rendered text including cursor + highlight
  cursor: Cursor         // Cursor position information
  offset: number         // Multiline scroll offset
}
```

**Supported keybindings (Emacs style)**:
- `Ctrl+A/E`: Line start/end
- `Ctrl+B/F`: Character-level movement
- `Ctrl+K`: Delete to end of line (kill)
- `Ctrl+U`: Delete to start of line
- `Ctrl+W`: Delete word (kill)
- `Ctrl+Y`: Yank (paste from kill ring)
- `Alt+Y`: Yank-pop (cycle kill ring)
- `Ctrl+_`: Undo
- `Ctrl+T`: Transpose characters

### 7.3 useCanUseTool Details

A hook that determines tool usability. Comprehensively evaluates tool permission policies, user settings, and MCP configuration.

### 7.4 useKeybinding Details

```typescript
// src/keybindings/useKeybinding.ts
function useKeybinding(
  action: string,                    // 'chat:submit', 'confirm:yes', ...
  handler: () => void,
  options?: {
    context?: KeybindingContextName  // Active context
    isActive?: boolean               // Whether active
  }
)

// Internal behavior:
// 1. Query bindings and activeContexts from KeybindingContext
// 2. Receive key input via useInput()
// 3. Call resolveKey(input, key, activeContexts, bindings)
// 4. Execute handler() on match
```

---

## 8. Keybinding System

### 8.1 Architecture (14 files)

```
src/keybindings/
├── schema.ts              # Zod schema (context, action definitions)
├── parser.ts              # Keystroke string parsing
├── match.ts               # Key input matching logic
├── resolver.ts            # Key → action resolution
├── defaultBindings.ts     # Default binding definitions
├── reservedShortcuts.ts   # Reserved/non-rebindable shortcuts
├── loadUserBindings.ts    # Load user keybindings.json
├── validate.ts            # Binding validation
├── template.ts            # Keybinding template
├── shortcutFormat.ts      # Display format conversion
├── KeybindingContext.tsx   # React context
├── KeybindingProviderSetup.tsx  # Provider initialization
├── useKeybinding.ts       # Keybinding hook
└── useShortcutDisplay.ts  # Shortcut display hook
```

### 8.2 Context-Based Priority

```typescript
// src/keybindings/schema.ts
const KEYBINDING_CONTEXTS = [
  'Global',          // Active everywhere
  'Chat',            // When chat input is focused
  'Autocomplete',    // When autocomplete menu is displayed
  'Confirmation',    // When confirmation/permission dialog is displayed
  'Help',            // Help overlay
  'Transcript',      // Transcript viewer
  'HistorySearch',   // Ctrl+R history search
  'Task',            // During task/agent execution
  'ThemePicker',     // Theme picker
  'Settings',        // Settings menu
  'Tabs',            // Tab navigation
  'Attachments',     // Attachment browsing
  'Footer',          // Bottom indicator
  'MessageSelector', // Message selection (rewind)
  'DiffDialog',      // Diff dialog
  'ModelPicker',     // Model picker
  'Select',          // Selection/list
  'Plugin',          // Plugin dialog
] as const
```

**Priority**: The most specific context in the active context list takes precedence. For example:
- `['Autocomplete', 'Chat', 'Global']` → Autocomplete > Chat > Global
- For the same key, the binding from the more specific context takes priority

### 8.3 Chord Support

```typescript
// src/keybindings/parser.ts

// Single keystroke parsing
function parseKeystroke(input: string): ParsedKeystroke {
  // "ctrl+shift+k" → { key: 'k', ctrl: true, shift: true, ... }
  // Modifier aliases: ctrl/control, alt/opt/option/meta, cmd/command/super/win
  // Special keys: esc→escape, return→enter, space→' ', arrows→up/down/left/right
}

// Chord parsing
function parseChord(input: string): Chord {
  // "ctrl+k ctrl+s" → [ParsedKeystroke, ParsedKeystroke]
  // " " (space alone) → [{ key: ' ' }]
  return input.trim().split(/\s+/).map(parseKeystroke)
}

// Actual use cases:
// 'ctrl+x ctrl+k' → chat:killAgents (2-key chord)
// 'ctrl+x ctrl+e' → chat:externalEditor
```

### 8.4 Key Matching

```typescript
// src/keybindings/match.ts

// Ink Key → normalized key name
function getKeyName(input: string, key: Key): string | null {
  if (key.escape) return 'escape'
  if (key.return) return 'enter'
  if (key.tab) return 'tab'
  if (key.upArrow) return 'up'
  if (key.downArrow) return 'down'
  // ... special key mapping
  if (input.length === 1) return input.toLowerCase()
  return null
}

// Modifier matching
function modifiersMatch(inkMods: InkModifiers, target: ParsedKeystroke): boolean {
  if (inkMods.ctrl !== target.ctrl) return false
  if (inkMods.shift !== target.shift) return false
  // Alt and Meta are identical in terminals (merged as key.meta)
  const targetNeedsMeta = target.alt || target.meta
  if (inkMods.meta !== targetNeedsMeta) return false
  // Super (Cmd/Win) is a separate modifier (Kitty protocol only)
  if (inkMods.super !== target.super) return false
  return true
}

// Escape key quirk: Ink sets key.meta=true on escape
// → Ignore meta when matching the escape key itself
```

### 8.5 Resolver

```typescript
// src/keybindings/resolver.ts
type ResolveResult =
  | { type: 'match'; action: string }    // Matched action
  | { type: 'none' }                     // No match
  | { type: 'unbound' }                  // Unbound via null

type ChordResolveResult =
  | ResolveResult
  | { type: 'chord_started'; pending: ParsedKeystroke[] }  // Chord first key
  | { type: 'chord_cancelled' }                             // Chord cancelled

function resolveKey(
  input: string,
  key: Key,
  activeContexts: KeybindingContextName[],
  bindings: ParsedBinding[],
): ResolveResult {
  // Last match wins (user overrides load after defaults)
  let match: ParsedBinding | undefined
  const ctxSet = new Set(activeContexts)

  for (const binding of bindings) {
    if (binding.chord.length !== 1) continue  // Single keys only (Phase 1)
    if (!ctxSet.has(binding.context)) continue
    if (matchesBinding(input, key, binding)) {
      match = binding  // Keep last match (last wins)
    }
  }

  if (!match) return { type: 'none' }
  if (match.action === null) return { type: 'unbound' }
  return { type: 'match', action: match.action }
}
```

### 8.6 Default Bindings

```typescript
// src/keybindings/defaultBindings.ts
const DEFAULT_BINDINGS: KeybindingBlock[] = [
  {
    context: 'Global',
    bindings: {
      'ctrl+c': 'app:interrupt',       // Non-rebindable
      'ctrl+d': 'app:exit',            // Non-rebindable
      'ctrl+l': 'app:redraw',
      'ctrl+t': 'app:toggleTodos',
      'ctrl+o': 'app:toggleTranscript',
      'ctrl+shift+o': 'app:toggleTeammatePreview',
      'ctrl+r': 'history:search',
    },
  },
  {
    context: 'Chat',
    bindings: {
      'escape': 'chat:cancel',
      'ctrl+x ctrl+k': 'chat:killAgents',    // Chord binding
      'shift+tab': 'chat:cycleMode',          // Platform-specific (Windows: meta+m)
      'meta+p': 'chat:modelPicker',
      'enter': 'chat:submit',
      'up': 'history:previous',
      'down': 'history:next',
      'ctrl+_': 'chat:undo',
      'ctrl+x ctrl+e': 'chat:externalEditor', // Chord binding
      'ctrl+g': 'chat:externalEditor',
      'ctrl+s': 'chat:stash',
      'ctrl+v': 'chat:imagePaste',            // Windows: alt+v
    },
  },
  {
    context: 'Autocomplete',
    bindings: {
      'tab': 'autocomplete:accept',
      'escape': 'autocomplete:dismiss',
      // ...
    },
  },
  {
    context: 'Confirmation',
    bindings: {
      'y': 'confirm:yes',
      'n': 'confirm:no',
      'tab': 'confirm:nextField',
      // ...
    },
  },
  // ... additional contexts
]
```

### 8.7 Reserved Shortcuts

```typescript
// src/keybindings/reservedShortcuts.ts

// Never rebindable
const NON_REBINDABLE = [
  { key: 'ctrl+c', reason: 'Interrupt/exit (hardcoded)' },
  { key: 'ctrl+d', reason: 'Exit (hardcoded)' },
  { key: 'ctrl+m', reason: 'Same as Enter in terminal (CR)' },
]

// Shortcuts intercepted by terminal/OS
const TERMINAL_RESERVED = [
  { key: 'ctrl+z', reason: 'Unix SIGTSTP' },
  { key: 'ctrl+\\', reason: 'Terminal SIGQUIT' },
]

// macOS specific
const MACOS_RESERVED = [
  { key: 'cmd+c', reason: 'macOS Copy' },
  { key: 'cmd+v', reason: 'macOS Paste' },
  { key: 'cmd+q', reason: 'macOS Quit' },
  { key: 'cmd+tab', reason: 'macOS App Switch' },
  // ...
]
```

### 8.8 User Customization

Users override bindings via `~/.claude/keybindings.json`:

```json
{
  "$schema": "...",
  "bindings": [
    {
      "context": "Chat",
      "bindings": {
        "ctrl+enter": "chat:submit",
        "enter": "chat:newline",
        "ctrl+s": null
      }
    }
  ]
}
```

- Setting to `null` unbinds the default binding
- Command bindings like `command:help` are also supported
- Loaded after default bindings, overriding via "last wins" rule

---

## 9. React Compiler

### 9.1 _c(N) Memoization Pattern

All components in Claude Code are compiled with the React Compiler, using the `_c(N)` pattern.

```typescript
import { c as _c } from "react/compiler-runtime"

function MyComponent(t0) {
  const $ = _c(8)  // Memoization cache with 8 slots
  const { name, onClick } = t0

  // Conditional memoization: return cache if dependencies haven't changed
  let t1
  if ($[0] !== name) {
    t1 = <Text>{name}</Text>
    $[0] = name      // Store dependency
    $[1] = t1        // Store result
  } else {
    t1 = $[1]        // Cache hit
  }

  let t2
  if ($[2] !== onClick || $[3] !== t1) {
    t2 = <Box onClick={onClick}>{t1}</Box>
    $[2] = onClick
    $[3] = t1
    $[4] = t2
  } else {
    t2 = $[4]
  }

  return t2
}
```

### 9.2 Optimization Effects

- **Automatic `React.memo`**: All components automatically get props-comparison-based memoization
- **Automatic `useMemo`/`useCallback`**: JSX expressions and callbacks are cached based on dependencies
- **No manual optimization needed**: `React.memo()`, `useMemo()`, `useCallback()` wrappers removed
- **Props destructuring**: Receives entire props as `t0`, then destructures internally (Compiler convention)

### 9.3 Cache Slot Allocation

The N in `_c(N)` is proportional to the number of memoization points in the component:
- Simple components: `_c(5)` ~ `_c(10)`
- Complex components: `_c(30)` ~ `_c(50)` (Button: 30, Box: 42)
- Giant components like REPL: `_c(94)` (Message)

---

## 10. Virtual Scrolling

### 10.1 VirtualMessageList

```typescript
// src/components/VirtualMessageList.tsx
type Props = {
  messages: RenderableMessage[]
  scrollRef: RefObject<ScrollBoxHandle | null>
  columns: number                    // Invalidate height cache on width change
  itemKey: (msg) => string           // Message unique key
  renderItem: (msg, index) => ReactNode  // Message render function
  onItemClick?: (msg) => void        // Click handler
  isItemClickable?: (msg) => boolean // Whether clickable
  isItemExpanded?: (msg) => boolean  // Expanded state
  extractSearchText?: (msg) => string  // Search text extraction (pre-lowered)
  trackStickyPrompt?: boolean        // Track sticky prompt
  jumpRef?: RefObject<JumpHandle>    // Search/jump handle
  onSearchMatchesChange?: (count, current) => void  // Search match change
}
```

### 10.2 useVirtualScroll Hook

The hook responsible for the core virtual scrolling logic:

```typescript
// src/hooks/useVirtualScroll.ts
// Internal behavior:
// 1. Calculate visible range from scrollTop and viewportHeight
// 2. Height cache (heightCache): Record rendered height per message
// 3. Only mount messages within the visible range in React
// 4. Out of range → VirtualScrollSpacer (empty Box with height)
// 5. Invalidate entire cache on columns change (text rewrap)
```

### 10.3 Message Batching

- Only mount visible area + headroom based on scroll position
- `HEADROOM = 3` lines of extra space
- Messages outside the visible range are replaced with Spacers (height preserved only)

### 10.4 Offscreen Freeze (OffscreenFreeze)

```typescript
// src/components/OffscreenFreeze.tsx
// Messages outside the viewport transition to "frozen" state
// React.memo + shouldComponentUpdate optimization
// "Thaw" and re-render when entering the visible range
```

### 10.5 JumpHandle (Search/Navigation)

```typescript
type JumpHandle = {
  jumpToIndex(i: number): void       // Jump to index
  setSearchQuery(q: string): void    // Set search query
  nextMatch(): void                  // Next match
  prevMatch(): void                  // Previous match
  setAnchor(): void                  // Set search anchor
  warmSearchIndex(): Promise<number> // Warm search index
  disarmSearch(): void               // Disarm search
}
```

### 10.6 StickyPrompt (Fixed Prompt Header)

Displays the first visible user prompt pinned to the top of the screen while scrolling:
- `StickyTracker`: Tracks scroll position inside VirtualMessageList
- `ScrollChromeContext`: Passes sticky prompt info to FullscreenLayout
- Text is limited to `STICKY_TEXT_CAP = 500` characters

### 10.7 Scroll Performance Optimization

```
ScrollBox (imperative)
  │
  ├─ Direct DOM scrollTop modification (bypasses React state)
  │
  ├─ pendingScrollDelta: limits max movement per frame
  │   → Shows intermediate frames during fast flicks
  │
  ├─ scrollClampBounds: virtual scroll clamp
  │   → Prevents scrolling beyond mounted content range
  │
  ├─ stickyScroll: bottom-fixed mode
  │   → Auto-tracks as content grows
  │
  └─ scrollAnchor: element-based scrolling
      → Reads yogaNode.getComputedTop() at render time
      → Prevents race conditions with throttled rendering
```

---

## Implementation Checklist

### Minimum Required Implementation (MVP)

- [ ] React-based terminal rendering engine (Reconciler + DOM + Layout)
- [ ] Yoga WASM flexbox integration
- [ ] Box, Text, ScrollBox core components
- [ ] Keyboard input parsing and event system
- [ ] ANSI tokenizer/parser (SGR, CSI)
- [ ] Double buffer screen + diff-based output
- [ ] Alt-screen support
- [ ] Basic keybinding system
- [ ] REPL screen basic structure

### Phase 2 Implementation

- [ ] DOM-style capture/bubble event propagation
- [ ] Chord keybindings (2-key chords)
- [ ] Virtual scrolling + height cache
- [ ] Text selection (mouse drag)
- [ ] Search highlighting
- [ ] Design system (Theme, Dialog, Tabs, FuzzyPicker)
- [ ] Permission dialog system
- [ ] Spinner animations

### Phase 3 Implementation

- [ ] React Compiler integration (_c(N) pattern)
- [ ] RawAnsi bypass component
- [ ] NoSelect text selection prevention
- [ ] StickyPrompt fixed header
- [ ] FocusManager + tab navigation
- [ ] Hyperlink support (OSC 8)
- [ ] Tab status display (OSC 21337)
- [ ] Kitty keyboard protocol support
- [ ] User keybinding customization
- [ ] Performance profiling (commit log, Yoga counters)

---

## Implementation Caveats

### C1. React 19 Concurrency Features Disabled
`maySuspendCommit()` always returns `false` in the custom reconciler. React 19 concurrency features such as `Suspense` and `useTransition()` **do not work**. All commits are synchronous.

### C2. Render Errors — No Error Boundary
There is no Error Boundary implementation in the custom reconciler. If a throw occurs during component rendering, the **entire TUI crashes**. Must defend with component-level try-catch.

### C3. Percent Width — Yoga Constraint
When setting `width="50%"`, the parent must have an **explicit width**. If the parent has auto sizing, the percent value becomes 0 or is ignored. This is a Yoga flexbox constraint.

### C4. Terminal Resize — No Debounce
Resize events are **processed immediately without debounce**. If a resize occurs during Yoga layout calculation, inconsistent layouts may result.

### C5. Virtual Scroll — Dynamic Height Constraint
Virtual scrolling assumes **fixed or pre-calculated item heights**. When heights change due to text wrapping, offset calculations become incorrect, causing visual artifacts.

### C6. SSH Environment Mouse Events
Mouse tracking escape codes may not be transmitted in SSH sessions. Features depending on mouse events need keyboard-only fallback after SSH detection.
