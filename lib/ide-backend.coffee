# Node module dependencies
path = require 'path'
fs   = require 'fs'

# Atom dependencies
{CompositeDisposable, Emitter} = require 'atom'

# Internal dependencies
Util = require 'atom-haskell-utils'
CabalProcess = null
TargetListView = null
ProjectListView = null
BuilderListView = null

module.exports =
class IdeBackend

  constructor: (@upi) ->
    @disposables = new CompositeDisposable

    @disposables.add @upi.addConfigParam
      builder:
        items: ->
          builders = [{name: 'cabal'}, {name: 'stack'}]
          if atom.config.get('ide-haskell-cabal.enableNixBuild')
            builders.push {name: 'cabal-nix'}
          builders.push {name: 'none'}
          builders
        itemTemplate: (item) ->
          "<li>
            <div class='name'>#{item.name}</div>
          </li>
          "
        displayTemplate: (item) ->
          item?.name ? "Not set"
        itemFilterKey: "name"
        description: 'Select builder to use with current project'
      target:
        default: {}
        items: ->
          projects =
            atom.project.getDirectories().map (d) ->
              dir = d.getPath()
              cabalRoot = Util.getRootDir dir
              [cabalFile] =
                cabalRoot.getEntriesSync().filter (file) ->
                  file.isFile() and file.getBaseName().endsWith '.cabal'
              {dir, cabalFile}
            .filter ({cabalFile}) -> cabalFile?
            .map ({dir, cabalFile}) ->
              cabalFile.read()
              .then (data) ->
                new Promise (resolve) ->
                  Util.parseDotCabal data, resolve
              .then (project) ->
                project.targets.unshift({})
                return project.targets.map (t) ->
                  t.project = project.name
                  t.dir = dir
                  t
          Promise.all(projects)
          .then (projects) ->
            [{}].concat projects...
        itemTemplate: (tgt) ->
          "<li>
            <div class='project'>#{tgt?.project ? 'Auto'}</div>
            <div class='dir'>#{(tgt?.dir unless tgt.type?) ? ''}</div>
            <div class='type'>#{tgt?.type ? ''}</div>
            <div class='name'>#{tgt?.name ? 'All'}</div>
            <div class='clearfix'></div>
          </li>
          "
        displayTemplate: (item) ->
          unless item?.project?
            "Auto"
          else
            "#{item.project}: #{item?.name ? 'All'}"
        itemFilterKey: "name"
        description: 'Select target to build'

  destroy: ->
    @disposables.dispose()
    @upi = null

  getActiveProjectPath: ->
    editor = atom.workspace.getActiveTextEditor()
    if editor?.getPath?()?
      path.dirname editor.getPath()
    else
      atom.project.getPaths()[0] ? process.cwd()

  cabalBuild: (cmd, opts) =>
    # It shouldn't be possible to call this function until cabalProcess
    # exits. Otherwise, problems will ensue.
    return Promise.resolve({}) if @running
    @running = true

    Promise.all [@upi.getConfigParam('builder'), @upi.getConfigParam('target')]
    .then ([builder, target]) =>
      @upi.setStatus
        status: 'progress'
        progress:
          if opts.onProgress?
            0.0
          else
            null

      cabalRoot = Util.getRootDir(target.dir ? @getActiveProjectPath())

      [cabalFile] =
        cabalRoot.getEntriesSync().filter (file) ->
          file.isFile() and file.getBaseName().endsWith '.cabal'

      if cabalFile?
        builder = try require "./builders/#{builder.name}"
        if builder?
          (new builder).build {
            cmd
            opts
            target
            cabalRoot
          }
        else
          throw new Error("Unknown builder '#{builder?.name ? builder}'")
      else
        @upi.addMessages [
          message: 'No cabal file found'
          severity: 'error'
        ]
        return {}
    .then (res) =>
      @running = false
      return res
    .catch (error) =>
      @running = false
      if error?
        console.error error
        atom.notifications.addFatalError error.toString(),
          detail: error
          dismissable: true
      return {}

  runCabalCommand: (command, {messageTypes, defaultSeverity, canCancel}) ->
    @upi.clearMessages messageTypes

    cancelActionDisp = null
    @cabalBuild command,
      severity: defaultSeverity
      setCancelAction:
        if canCancel
          (action) =>
            cancelActionDisp?.dispose?()
            cancelActionDisp = @upi.addPanelControl 'ide-haskell-button',
              classes: ['cancel']
              events:
                click: ->
                  action()
              before: '#progressBar'
      onMsg: (messages) =>
        @upi.addMessages messages.filter ({severity}) -> severity in messageTypes
      onProgress:
        if canCancel
          (progress) =>
            @upi.setStatus {status: 'progress', progress}
    .then ({exitCode, hasError}) =>
      cancelActionDisp?.dispose?()
      @upi.setStatus status: 'ready'
      # cabal returns failure when there are type errors _or_ when it can't
      # compile the code at all (i.e., when there are missing dependencies).
      # Since it's hard to distinguish between these days, we look at the
      # parsed errors; if there are any, we assume that it at least managed to
      # start compiling (all dependencies available) and so we ignore the
      # exit code and just report the errors. Otherwise, we show an atom error
      # with the raw stderr output from cabal.
      if exitCode != 0
        if hasError
          @upi.setStatus status: 'warning'
        else
          @upi.setStatus status: 'error'

  ### Public interface below ###

  build: ->
    @runCabalCommand 'build',
      messageTypes: ['error', 'warning', 'build']
      defaultSeverity: 'build'
      canCancel: true

  clean: ->
    @runCabalCommand 'clean',
      messageTypes: ['build']
      defaultSeverity: 'build'
      canCancel: false

  test: ->
    @runCabalCommand 'test',
      messageTypes: ['error', 'warning', 'build', 'test']
      defaultSeverity: 'test'
      canCancel: true

  dependencies: ->
    @runCabalCommand 'deps',
      messageTypes: ['build']
      defaultSeverity: 'build'
      canCancel: true
