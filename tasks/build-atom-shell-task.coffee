fs = require 'fs'
path = require 'path'
rx = require 'rx'
_ = require 'underscore'

module.exports = (grunt) ->
  {cp, mkdir, rm, spawn} = require('./task-helpers')(grunt)

  spawnObservable = (options={}) ->
    rx.Observable.create (subj) ->
      grunt.verbose.ok "Running: #{options.cmd} #{options.args.join ' '}"

      spawn options, (error, result, code) ->
        if error
          subj.onError error
          return

        subj.onNext {error,result,code}
        subj.onCompleted()

      rx.Disposable.empty

  bootstrapAtomShell = (buildDir, atomShellDir, remoteUrl, tag) ->
    cmds = [
      { cmd: 'git', args: ['fetch', 'origin'], opts: {cwd: atomShellDir} },
      { cmd: 'git', args: ['checkout', tag, ], opts: {cwd: atomShellDir} },
      { cmd: 'git', args: ['reset', '--hard', 'HEAD'], opts: {cwd: atomShellDir} },
    ]

    if fs.existsSync(atomShellDir)
      cmds.unshift { cmd: 'git', args: ['remote', 'set-url', 'origin', remoteUrl], opts: {cwd: atomShellDir} },
    else
      rm atomShellDir

      grunt.verbose.ok "Cloning to #{buildDir}"
      grunt.file.mkdir buildDir
      cmds.unshift { cmd: 'git', args: ['clone', remoteUrl], opts: {cwd: buildDir} },

    bootstrapAtomShell = rx.Observable.fromArray(cmds)
      .concatMap (x) -> spawnObservable(x)
      .takeLast(1)

  buildAtomShell = (atomShellDir, config, projectName, productName) ->
    bootstrapCmd =
      cmd: 'python'
      args: ['script/bootstrap.py']
      opts: {cwd: atomShellDir}

    buildCmd =
      cmd: 'python'
      args: ['script/build.py', '-c', config, '-t', projectName]
      opts: {cwd: atomShellDir}

    rx.Observable.create (subj) ->
      grunt.verbose.ok "Rigging atom.gyp to have correct name"
      gypFile = path.join(atomShellDir, 'atom.gyp')
      atomGyp = grunt.file.read gypFile
      atomGyp = atomGyp
        .replace("'project_name': 'atom'", "'project_name': '#{projectName}'")
        .replace("'product_name': 'Atom'", "'product_name': '#{productName}'")
        .replace("'framework_name': 'Atom Framework'", "'framework_name': '#{productName} Framework'")

      grunt.file.write gypFile, atomGyp

      canary = path.join(atomShellDir, 'atom', 'common', 'chrome_version.h')
      bootstrap = spawnObservable(bootstrapCmd)
      bootstrap = rx.Observable.return(true) if fs.existsSync(canary)

      rx.Observable.concat(bootstrap, spawnObservable(buildCmd))
        .takeLast(1)
        .subscribe(subj)

  generateNodeLib = (atomShellDir, config) ->
    return rx.Observable.return(true) unless process.platform is 'win32'

    source = path.resolve atomShellDir, 'out', 'Release', 'node.lib'
    target = path.resolve process.env.USERPROFILE, '.atom', '.node-gyp', '.node-gyp', '0.18.0', 'ia32', 'node.lib'

    if fs.existsSync(source)
      cp source, target
      return rx.Observable.return(true)

    buildNodeLib =
      cmd: 'python'
      args: ['script/build.py', '-c', config, '-t', 'generate_node_lib']
      opts: { cwd: atomShellDir }

    spawnObservable(buildNodeLib).do(-> cp source, target)

  rebuildNativeModules = ->
    nodeArch = switch process.platform
      when 'darwin' then 'x64'
      when 'win32' then 'ia32'
      else process.arch

    nodeVersion = process.env.ATOM_NODE_VERSION ? '0.18.0'

    homeDir = if process.platform is 'win32' then process.env.USERPROFILE else process.env.HOME
    atomHome = process.env.ATOM_HOME ? path.join(homeDir, '.atom')
    nodeGypHome =  path.join(atomHome, '.node-gyp')

    cmd = 'node'
    args = [require.resolve('npm/bin/npm-cli'), 'rebuild', "--target=#{nodeVersion}", "--arch=#{nodeArch}"]
    env = _.extend {}, process.env, HOME: nodeGypHome
    env.USERPROFILE = env.HOME if process.platform is 'win32'

    rx.Observable.create (subj) ->
      grunt.verbose.ok 'Rebuilding native modules against Atom Shell'
      spawnObservable({cmd, args, opts: {env}}).subscribe(subj)

  grunt.registerTask 'build-atom-shell', 'Build Atom Shell from source', ->
    done = @async()

    @requiresConfig "#{@name}.buildDir", "#{@name}.tag", "#{@name}.projectName", "#{@name}.productName"

    {buildDir, targetDir, config, remoteUrl, projectName, productName, tag} = grunt.config @name
    config ?= 'Release'
    remoteUrl ?= 'https://github.com/atom/atom-shell'
    targetDir ?= 'atom-shell'
    atomShellDir = path.join buildDir, 'atom-shell'

    buildErrything = rx.Observable.concat(
      bootstrapAtomShell(buildDir, atomShellDir, remoteUrl, tag),
      buildAtomShell(atomShellDir, config, projectName, productName),
      generateNodeLib(atomShellDir, config),
      rebuildNativeModules()).takeLast(1)

    buildErrything
      .map (x) ->
        rm 'atom-shell'
        cp(path.resolve(atomShellDir, 'out', config), 'atom-shell')
        return x
      .subscribe(( ->), done, done)
