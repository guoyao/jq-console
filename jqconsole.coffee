# Shorthand for jQuery.
$ = jQuery

# The states in which the console can be.
STATE_INPUT = 0
STATE_OUTPUT = 1
STATE_PROMPT = 2

# Key code values.
KEY_ENTER = 13
KEY_TAB = 9
KEY_DELETE = 46
KEY_BACKSPACE = 8
KEY_LEFT = 37
KEY_RIGHT = 39
KEY_UP = 38
KEY_DOWN = 40
KEY_HOME = 36
KEY_END = 35

# Default prompt text for main and continuation prompts.
DEFAULT_PROMPT_LABEL = '>>> '
DEFAULT_PROMPT_CONINUE_LABEL = '... '

# The default number of spaces inserted when indenting.
DEFAULT_INDENT_WIDTH = 2

class JQConsole
  # Creates a console.
  #   @arg container: The DOM element into which the console is inserted.
  #   @arg header: Text to print at the top of the console on reset. Optional.
  #     Defaults to an empty string.
  #   @arg prompt_label: The label to show before the command prompt. Optional.
  #     Defaults to DEFAULT_PROMPT_LABEL.
  #   @arg prompt_continue: The label to show before continuation lines of the
  #     command prompt. Optional. Defaults to DEFAULT_PROMPT_CONINUE_LABEL.
  constructor: (container, header, prompt_label, prompt_continue_label) ->
    # The header written when the console is reset.
    @header = header or ''

    # The prompt label used by Prompt().
    @prompt_label_main = prompt_label or DEFAULT_PROMPT_LABEL
    @prompt_label_continue = '\n' + (prompt_continue_label or
                                     DEFAULT_PROMPT_CONINUE_LABEL)

    # How many spaces are inserted when a tab character is pressed.
    @indent_width = DEFAULT_INDENT_WIDTH

    # By default, the console is in the output state.
    @state = STATE_OUTPUT

    # A queue of input/prompt operations waiting to be called. The items are
    # bound functions ready to be called.
    @input_queue = []

    # The function to call when input is accepted. Valid only in
    # input/prompt mode.
    @input_callback = null
    # The function to call to determine whether the input should continue to the
    # next line.
    @multiline_callback = null

    # A table of all "recorded" inputs given so far.
    @history = []
    # The index of the currently selected history item. If this is past the end
    # of @history, then the user has not selected a history item.
    @history_index = 0
    # The command which the user was typing before browsing history. Keeping
    # track of this allows us to restore the user's command if they browse the
    # history then decide to go back to what they were typing.
    @history_new = ''
    # Whether the current input operation is using history.
    @history_active = false

    # A table of custom shortcuts, mapping character codes to callbacks.
    @shortcuts = {}

    # The main console area. Everything else happens inside this.
    @$console = $('<pre class="jqconsole"/>').appendTo container

    # A hidden textbox which captures the user input when the console is in
    # input mode. Needed to be able to intercept paste events.
    @$input_source = $('<textarea/>')
    @$input_source.css position: 'absolute', left: '-9999px'
    @$input_source.appendTo container

    # Prepare console for interaction.
    @_InitPrompt()
    @_SetupEvents()
    @Write @header, 'jqconsole-header'

    # Save this instance to be accessed if lost.
    $(container).data 'jqconsole', this

  # Resets the console to its initial state.
  Reset: ->
    if @state != STATE_OUTPUT then @ClearPromptText true
    @state = STATE_OUTPUT
    @input_queue = []
    @input_callback = null
    @multiline_callback = null
    @history = []
    @history_index = 0
    @history_current = ''
    @shortcuts = {}
    @$prompt.detach()
    @$console.html ''
    @$prompt.appendTo @$console
    @Write @header, 'jqconsole-header'
    return undefined

  # Registers a Ctrl+Key shortcut.
  #   @arg key_code: The code of the key pressing which (when Ctrl is held) will
  #     trigger this shortcut. If a string is provided, the character code of
  #     the first character is taken.
  #   @arg callback: A function called when the shortcut is pressed; "this" will
  #     point to the JQConsole object.
  RegisterShortcut: (key_code, callback) ->
    if isNaN key_code
      key_code = key_code.charCodeAt 0
    else
      key_code = parseInt key_code, 10

    if not (0 < key_code < 256) or isNaN key_code
      throw new Error 'Key code must be a number between 0 and 256 exclusive.'
    if not callback instanceof Function
      throw new Error 'Callback must be a function, not ' + callback + '.'

    addShortcut = (key) =>
      if key not of @shortcuts then @shortcuts[key] = []
      @shortcuts[key].push callback
    addShortcut key_code
    if 65 <= key_code <= 90 then addShortcut key_code + 32
    if 97 <= key_code <= 122 then addShortcut key_code - 32
    return undefined

  # Returns the 0-based number of the column on which the cursor currently is.
  GetColumn: ->
    @$prompt_cursor.text ''
    lines = @$console.text().split '\n'
    @$prompt_cursor.text ' '
    return lines[lines.length - 1].length

  # Returns the 0-based number of the line on which the cursor currently is.
  GetLine: ->
    return @$console.text().split('\n').length - 1

  # Clears the contents of the prompt.
  #   @arg clear_label: If true, also clears the main prompt label (e.g. ">>>").
  ClearPromptText: (clear_label) ->
    if @state == STATE_OUTPUT
      throw new Error 'ClearPromptText() is not allowed in output state.'
    @$prompt_before.html ''
    @$prompt_after.html ''
    @$prompt_label.text if clear_label then '' else @_SelectPromptLabel false
    @$prompt_left.text ''
    @$prompt_right.text ''
    return undefined

  # Returns the contents of the prompt.
  #   @arg full: If true, also includes the prompt labels (e.g. ">>>").
  GetPromptText: (full) ->
    if @state == STATE_OUTPUT
      throw new Error 'GetPromptText() is not allowed in output state.'

    if full
      @$prompt_cursor.text ''
      text = @$prompt.text()
      @$prompt_cursor.text ' '
      return text
    else
      getPromptLines = (node) ->
        buffer = []
        node.children().each -> buffer.push $(':last-child', @).text()
        return buffer.join '\n'

      before = getPromptLines @$prompt_before
      if before then before += '\n'

      current = @$prompt_left.text() + @$prompt_right.text()

      after = getPromptLines @$prompt_after
      if after then after = '\n' + after

      return before + current + after

  # Sets the contents of the prompt.
  #   @arg text: The text to put in the prompt. May contain multiple lines.
  SetPromptText: (text) ->
    if @state == STATE_OUTPUT
      throw new Error 'SetPromptText() is not allowed in output state.'
    @ClearPromptText false
    @_AppendPromptText text
    @_ScrollToEnd()
    return undefined

  # Writes the given text to the console in a <span>, with an optional class.
  #   @arg text: The text to write.
  #   @arg cls: The class to give the span containing the text. Optional.
  Write: (text, cls) ->
    span = $('<span>').text text
    if cls? then span.addClass cls
    span.insertBefore @$prompt
    @_ScrollToEnd()
    # Force reclaculation of the cursor's position.
    @$prompt_cursor.detach().insertAfter @$prompt_left
    return undefined

  # Starts an input operation. If another input or prompt operation is currently
  # underway, the new input operation is enqueued and will be called when the
  # current operation and all previously enqueued operations finish.
  #   @arg input_callback: A function called with the user's input when the
  #     user presses Enter and the input operation is complete.
  Input: (input_callback) ->
    if @state != STATE_OUTPUT
      @input_queue.push => @Input input_callback
      return
    @history_active = false
    @input_callback = input_callback
    @multiline_callback = null
    @state = STATE_INPUT
    @$prompt.attr 'class', 'jqconsole-input'
    @$prompt_label.text @_SelectPromptLabel false
    @Focus()
    @_ScrollToEnd()
    return undefined

  # Starts a command prompt operation. If another input or prompt operation is
  # currently underway, the new prompt operation is enqueued and will be called
  # when the current operation and all previously enqueued operations finish.
  #   @arg history_enabled: Whether this input should use history. If true, the
  #     user can select the input from history, and their input will also be
  #     added as a new history item.
  #   @arg result_callback: A function called with the user's input when the
  #     user presses Enter and the prompt operation is complete.
  #   @arg multiline_callback: If specified, this function is called when the
  #     user presses Enter to check whether the input should continue to the
  #     next line. If this function returns a falsy value, the input operation
  #     is completed. Otherwise, input continues and the cursor moves to the
  #     next line.
  Prompt: (history_enabled, result_callback, multiline_callback) ->
    if @state != STATE_OUTPUT
      @input_queue.push =>
        @Prompt history_enabled, result_callback, multiline_callback
      return
    @history_active = history_enabled
    @input_callback = result_callback
    @multiline_callback = multiline_callback
    @state = STATE_PROMPT
    @$prompt.attr 'class', 'jqconsole-prompt'
    @$prompt_label.text @_SelectPromptLabel false
    @Focus()
    @_ScrollToEnd()
    return undefined

  # Aborts the current prompt operation and returns to output mode or the next
  # queued input/prompt operation.
  AbortPrompt: ->
    if @state != STATE_PROMPT
      throw new Error 'Cannot abort prompt when not in prompt state.'
    @Write @GetPromptText(true) + '\n', 'jqconsole-old-prompt'
    @ClearPromptText true
    @state = STATE_OUTPUT
    @input_callback = @multiline_callback = null
    @_CheckInputQueue()
    return undefined

  # Sets focus on the console's hidden input box so input can be read.
  Focus: ->
    @$input_source.focus()
    return undefined

  # Sets the number of spaces inserted when indenting.
  SetIndentWidth: (width) ->
    @indent_width = width

  # Returns the number of spaces inserted when indenting.
  GetIndentWidth: ->
    return @indent_width

  ###------------------------ Private Methods -------------------------------###

  _CheckInputQueue: ->
    if @input_queue.length
      @input_queue.shift()()

  # Creates the movable prompt span. When the console is in input mode, this is
  # shown and allows user input. The structure of the spans are as follows:
  # $prompt
  #   $prompt_before
  #     line1
  #       prompt_label
  #       prompt_content
  #     ...
  #     lineN
  #       prompt_label
  #       prompt_content
  #   $prompt_current
  #     $prompt_label
  #     $prompt_left
  #     $prompt_cursor
  #     $prompt_right
  #   $prompt_after
  #     line1
  #       prompt_label
  #       prompt_content
  #     ...
  #     lineN
  #       prompt_label
  #       prompt_content
  _InitPrompt: ->
    # The main prompt container.
    @$prompt = $('<span class="jqconsole-input"/>').appendTo @$console
    # The main divisions of the prompt - the lines before the current line, the
    # current line, and the lines after it.
    @$prompt_before = $('<span/>').appendTo @$prompt
    @$prompt_current = $('<span/>').appendTo @$prompt
    @$prompt_after = $('<span/>').appendTo @$prompt

    # The subdivisions of the current prompt line - the static prompt label
    # (e.g. ">>> "), and the editable text to the left and right of the cursor.
    @$prompt_label = $('<span/>').appendTo @$prompt_current
    @$prompt_left = $('<span/>').appendTo @$prompt_current
    @$prompt_right = $('<span/>').appendTo @$prompt_current

    # Needed for the CSS z-index on the cursor to work.
    @$prompt_right.css position: 'relative'

    # The cursor. A span containing a space that shades its following character.
    # If the font of the prompt is not monospace, the content should be set to
    # the first character of @$prompt_right to get the appropriate width.
    @$prompt_cursor = $('<span class="jqconsole-cursor"> </span>')
    @$prompt_cursor.insertBefore @$prompt_right
    @$prompt_cursor.css
      color: 'transparent'
      display: 'inline'
      position: 'absolute'
      zIndex: 0

  # Binds all the required input and focus events.
  _SetupEvents: ->
    # Redirect focus to the hidden textbox unless we selected something.
    @$console.click =>
      getSelection = ->
        if window.getSelection
          return window.getSelection().toString()
        else if document.selection?.type == "Text"
          return document.selection.createRange().text
      if getSelection() == '' then @Focus()

    # Intercept pasting.
    paste_event = if $.browser.opera then 'input' else 'paste'
    @$input_source.bind paste_event, =>
      handlePaste = =>
        @_AppendPromptText @$input_source.val()
        @$input_source.val ''
        @Focus()
      # Wait until the browser has handled the paste event before scraping.
      setTimeout handlePaste, 0

    # Actual key-by-key handling.
    @$input_source.keypress (e) => @_HandleChar e
    key_event = if $.browser.mozilla then 'keypress' else 'keydown'
    @$input_source[key_event] (e) => @_HandleKey e

  # Handles a character key press.
  #   @arg event: The jQuery keyboard Event object to handle.
  _HandleChar: (event) ->
    # We let the browser take over during output mode.
    if @state == STATE_OUTPUT then return true

    # IE & Chrome capture non-control characters and Enter.
    # Mozilla and Opera capture everything.

    # This is the most reliable cross-browser; charCode/keyCode break on Opera.
    char_code = event.which

    # Skip Enter on IE and Chrome and Tab on Opera. These are handled in
    # _HandleKey().
    if char_code == 13 or char_code == 9 then return false

    # Pass control characters which are captured on Mozilla.
    if $.browser.mozilla
       if event.keyCode or event.metaKey or event.ctrlKey or event.altKey
         return true
    # Pass control characters which are captured on Opera.
    if $.browser.opera
       if (event.keyCode or event.which or
           event.metaKey or event.ctrlKey or event.altKey)
         return true

    # Skip everything when a modifier key other than shift is held.
    if event.metaKey or event.ctrlKey or event.altKey then return false

    @$prompt_left.text @$prompt_left.text() + String.fromCharCode char_code
    @_ScrollToEnd()
    return false

  # Handles a key up event and dispatches specific handlers.
  #   @arg event: The jQuery keyboard Event object to handle.
  _HandleKey: (event) ->
    # We let the browser take over during output mode.
    if @state == STATE_OUTPUT then return true

    key = event.keyCode or event.which

    # Handle shortcuts.
    if event.altKey or event.metaKey and not event.ctrlKey
      # Allow Alt and Meta shortcuts.
      return true
    else if event.ctrlKey
      return @_HandleCtrlShortcut key
    else if event.shiftKey
      # Shift-modifier shortcut.
      switch key
        when KEY_ENTER then @_HandleEnter true
        when KEY_TAB then @_Unindent()
        when KEY_UP then  @_MoveUp()
        when KEY_DOWN then @_MoveDown()
        # Allow other Shift shortcuts to pass through to the browser.
        else return true
      return false
    else
      # Not a modifier shortcut.
      switch key
        when KEY_ENTER then @_HandleEnter false
        when KEY_TAB then @_Indent()
        when KEY_DELETE then @_Delete false
        when KEY_BACKSPACE then @_Backspace false
        when KEY_LEFT then @_MoveLeft false
        when KEY_RIGHT then @_MoveRight false
        when KEY_UP then @_HistoryPrevious()
        when KEY_DOWN then @_HistoryNext()
        when KEY_HOME then @_MoveToStart false
        when KEY_END then @_MoveToEnd false
        # Let any other key continue its way to keypress.
        else return true
      return false

  # Handles a Ctrl+Key shortcut.
  #   @arg key: The keyCode of the pressed key.
  _HandleCtrlShortcut: (key) ->
    switch key
      when KEY_DELETE then @_Delete true
      when KEY_BACKSPACE then @_Backspace true
      when KEY_LEFT then @_MoveLeft true
      when KEY_RIGHT then @_MoveRight true
      when KEY_UP then  @_MoveUp()
      when KEY_DOWN then @_MoveDown()
      when KEY_END then @_MoveToEnd true
      when KEY_HOME then @_MoveToStart true
      else
        if key of @shortcuts
          # Execute custom shortcuts.
          handler.call(this) for handler in @shortcuts[key]
          return false
        else
          # Allow unhandled Ctrl shortcuts.
          return true
    # Block handled shortcuts.
    return false

  # Handles the user pressing the Enter key.
  #   @arg shift: Whether the shift key is held.
  _HandleEnter: (shift) ->
    if shift
      @_InsertNewLine()
    else
      text = @GetPromptText()
      if @multiline_callback and @multiline_callback text
        @_MoveToEnd true
        @_InsertNewLine()
      else
        # Done with input.
        cls_suffix = if @state == STATE_INPUT then 'input' else 'prompt'
        @Write @GetPromptText(true) + '\n', 'jqconsole-old-' + cls_suffix
        @ClearPromptText true
        if @history_active
          if not @history.length or @history[@history.length - 1] != text
            @history.push text
            @history_index = @history.length
        @state = STATE_OUTPUT
        callback = @input_callback
        @input_callback = null
        if callback then callback text
        @_CheckInputQueue()

  # Moves the cursor to the line above the current one, in the same column.
  _MoveUp: ->
    if @$prompt_before.is ':empty' then return
    pos = @$prompt_left.text().length
    @_MoveToStart()
    @_MoveLeft()
    @$prompt_right.text @$prompt_left.text()[pos..]
    @$prompt_left.text @$prompt_left.text()[0...pos]

  # Moves the cursor to the line below the current one, in the same column.
  _MoveDown: ->
    if @$prompt_after.is ':empty' then return
    pos = @$prompt_left.text().length
    @_MoveToEnd()
    @_MoveRight()
    @$prompt_left.text @$prompt_right.text()[0...pos]
    @$prompt_right.text @$prompt_right.text()[pos..]

  # Moves the cursor to the left.
  #   @arg whole_word: Whether to move by a whole word rather than a character.
  _MoveLeft: (whole_word) ->
    text = @$prompt_left.text()
    if text
      if whole_word
        word = text.match /\w*\W*$/
        if not word then return
        word = word[0]
        @$prompt_right.text word + @$prompt_right.text()
        @$prompt_left.text text[...-word.length]
      else
        @$prompt_right.text text[-1...] + @$prompt_right.text()
        @$prompt_left.text text[...-1]
    else if not @$prompt_before.is ':empty'
      $lower_line = $('<span/>').prependTo @$prompt_after
      $lower_line.append $('<span/>').text @$prompt_label.text()
      $lower_line.append $('<span/>').text @$prompt_right.text()

      $upper_line = @$prompt_before.children().last().detach()
      @$prompt_label.text $upper_line.children().first().text()
      @$prompt_left.text $upper_line.children().last().text()
      @$prompt_right.text ''

  # Moves the cursor to the right.
  #   @arg whole_word: Whether to move by a whole word rather than a character.
  _MoveRight: (whole_word) ->
    text = @$prompt_right.text()
    if text
      if whole_word
        word = text.match /^\w*\W*/
        if not word then return
        word = word[0]
        @$prompt_left.text @$prompt_left.text() + word
        @$prompt_right.text text[word.length...]
      else
        @$prompt_left.text @$prompt_left.text() + text[0]
        @$prompt_right.text text[1...]
    else if not @$prompt_after.is ':empty'
      $upper_line = $('<span/>').appendTo @$prompt_before
      $upper_line.append $('<span/>').text @$prompt_label.text()
      $upper_line.append $('<span/>').text @$prompt_left.text()

      $lower_line = @$prompt_after.children().first().detach()
      @$prompt_label.text $lower_line.children().first().text()
      @$prompt_left.text ''
      @$prompt_right.text $lower_line.children().last().text()

  # Moves the cursor to the start of the current prompt line.
  #   @arg all_lines: If true, moves to the beginning of the first prompt line,
  #     instead of the beginning of the current.
  _MoveToStart: (all_lines) ->
    if all_lines
      # WARNING: @$prompt_left.is(':empty') hangs on Firefox 3.x.
      until @$prompt_before.is(':empty') and @$prompt_left.text() == ''
        @_MoveToStart false
        @_MoveLeft false
    else
      @$prompt_right.text @$prompt_left.text() + @$prompt_right.text()
      @$prompt_left.text ''

  # Moves the cursor to the end of the current prompt line.
  _MoveToEnd: (all_lines) ->
    if all_lines
      # WARNING: @$prompt_right.is(':empty') hangs on Firefox 3.x.
      until @$prompt_after.is(':empty') and @$prompt_right.text() == ''
        @_MoveToEnd false
        @_MoveRight false
    else
      @$prompt_left.text @$prompt_left.text() + @$prompt_right.text()
      @$prompt_right.text ''

  # Deletes the character or word following the cursor.
  #   @arg whole_word: Whether to delete a whole word rather than a character.
  _Delete: (whole_word) ->
    text = @$prompt_right.text()
    if text
      if whole_word
        word = text.match /^\w*\W*/
        if not word then return
        word = word[0]
        @$prompt_right.text text[word.length...]
      else
        @$prompt_right.text text[1...]
    else if not @$prompt_after.is ':empty'
      $lower_line = @$prompt_after.children().first().detach()
      @$prompt_right.text $lower_line.children().last().text()

  # Deletes the character or word preceding the cursor.
  #   @arg whole_word: Whether to delete a whole word rather than a character.
  _Backspace: (whole_word) ->
    text = @$prompt_left.text()
    if text
      if whole_word
        word = text.match /\w*\W*$/
        if not word then return
        word = word[0]
        @$prompt_left.text text[...-word.length]
      else
        @$prompt_left.text text[...-1]
    else if not @$prompt_before.is ':empty'
      $upper_line = @$prompt_before.children().last().detach()
      @$prompt_label.text $upper_line.children().first().text()
      @$prompt_left.text $upper_line.children().last().text()

  # Indents the current line.
  _Indent: ->
    @$prompt_left.prepend (' ' for _ in [1..@indent_width]).join ''

  # Unindents the current line.
  _Unindent: ->
    line_text = @$prompt_left.text() + @$prompt_right.text()
    for _ in [1..@indent_width]
      if not /^ /.test(line_text) then break
      if @$prompt_left.text()
        @$prompt_left.text @$prompt_left.text()[1..]
      else
        @$prompt_right.text @$prompt_right.text()[1..]
      line_text = line_text[1..]

  # Inserts a new line at the cursor position.
  _InsertNewLine: ->
    old_prompt = @_SelectPromptLabel not @$prompt_before.is ':empty'
    $old_line = $('<span/>').appendTo @$prompt_before
    $old_line.append $('<span/>').text old_prompt
    $old_line.append $('<span/>').text @$prompt_left.text()

    @$prompt_label.text @_SelectPromptLabel true
    @$prompt_left.text ''
    @_ScrollToEnd()

  # Appends the given text to the prompt.
  #   text: The text to append. Can contain multiple lines.
  _AppendPromptText: (text) ->
    lines = text.split '\n'
    @$prompt_left.text @$prompt_left.text() + lines[0]
    for line in lines[1..]
      @_InsertNewLine()
      @$prompt_left.text line

  # Scrolls the console area to its bottom.
  _ScrollToEnd: ->
    @$console.scrollTop @$console[0].scrollHeight

  # Selects the prompt label appropriate to the current mode.
  #   @arg continuation: If true, returns the continuation prompt rather than
  #     the main one.
  _SelectPromptLabel: (continuation) ->
    if @state == STATE_PROMPT
      return if continuation then @prompt_label_continue else @prompt_label_main
    else
      return if continuation then '\n ' else ' '

  # Sets the prompt to the previous history item.
  _HistoryPrevious: ->
    if not @history_active then return
    if @history_index <= 0 then return
    if @history_index == @history.length
      @history_new = @GetPromptText()
    @SetPromptText @history[--@history_index]

  # Sets the prompt to the next history item.
  _HistoryNext: ->
    if not @history_active then return
    if @history_index >= @history.length then return
    if @history_index == @history.length - 1
      @history_index++
      @SetPromptText @history_new
    else
      @SetPromptText @history[++@history_index]

$.fn.jqconsole = (header, prompt_main, prompt_continue) ->
  new JQConsole this, header, prompt_main, prompt_continue
