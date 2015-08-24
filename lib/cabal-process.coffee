# Node module dependencies
child_process = require 'child_process'
process       = require 'process'

# Atom dependencies
{Directory, Point} = require 'atom'

# Regular expression to match against a location in a cabal msg (Foo.hs:3:2)
# The [^] syntax basically means "anything at all" (including newlines)
matchLoc = /(\S+):(\d+):(\d+):( Warning:)?\n?([^]*)/

# Start of a Cabal message
startOfMessage = /\n\S/

module.exports =
class CabalProcess
  # Spawn a process and log all messages
  constructor: (command, args, options, {onMsg, onProgress, onDone}) ->
    @cwd = new Directory options.cwd
    proc = child_process.spawn command, args, options

    # TODO: Not sure how to make the cancel available
    # @configureButton "Cancel", (msgView) ->
    #   # Kill the entire process group
    #   # (E.g., if cabal spawns ghc, kill both)
    #   process.kill -proc.pid, 'SIGTERM'

    proc.stdout.on 'data', (data) ->
      match = data.toString().match /\[\s*([\d]+)\s+of\s+([\d]+)\s*\]/
      if match?
        [_, progress, total] = match
        onProgress(progress/total)
      onMsg [
        message: data.toString()
        severity: 'build'
      ]

    # TODO: For now we collect all messages before calling the callback
    # It would be better if we could call the callback incrementally (as we
    # discover messages) so that we can show messages coming in before cabal is
    # finished. This will require upstream changes in ide-haskell however.
    @messages = []

    # We collect stderr from the process as it comes in and split it into
    # individual errors/warnings. We also keep the unparsed error messages
    # to show in case of a cabal failure.
    @errBuffer = ""
    @rawErrors = ""

    hasError = false

    proc.stderr.on 'data', (data) =>
      @errBuffer += data.toString()
      msgs = @splitErrBuffer false
      for msg in msgs
        continue unless msg?
        if msg.uri?
          hasError = true
      onMsg msgs

    proc.on 'close', (code, signal) =>
      msgs = @splitErrBuffer true
      for msg in msgs
        if msg.uri?
          hasError = true
      onMsg msgs
      onDone code, hasError

  # Split the error buffer we have so far into messages
  splitErrBuffer: (isEOF) ->
     som = @errBuffer.search startOfMessage
     msgs = while som >= 0
       errMsg     = @errBuffer.substr(0, som + 1)
       @errBuffer = @errBuffer.substr(som + 1)
       som        = @errBuffer.search startOfMessage
       @parseMessage errMsg
     if isEOF
       # Try to parse whatever is left in the buffer
       msgs.push @parseMessage @errBuffer
     msgs.filter (msg) -> msg?

  parseMessage: (raw) ->
    if raw.trim() != ""
      matched = raw.match(matchLoc)
      if matched?
        [file, line, col, rawTyp, msg] = matched.slice(1, 6)
        typ = if rawTyp? then "warning" else "error"

        # TODO: The lines in the message will be indented by a fixed amount
        # We could potentially remove this (not a big deal, of course)
        uri: @cwd.getFile(file).getPath()
        position: new Point parseInt(line) - 1, parseInt(col) - 1
        message: msg.trimRight()
        severity: typ
      else
        # TODO: We should able to show these somewhere
        # Examples:
        # "WARNING in hptSomeThingsBelowUs↵    missing module…↵    Probable cause: out-of-date interface files↵"
        # console.log "Unable to parse", { "msg" : raw }
        message: raw
        severity: 'build'
