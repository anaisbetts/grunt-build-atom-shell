fs = require 'fs'
path = require 'path'
rx = require 'rx'
_ = require 'underscore'
glob = require 'glob'

module.exports = (grunt) ->
  {cp, mkdir, rm, spawn} = require('./task-helpers')(grunt)

  fixBorkedOSXPythonPath = (options) ->
    return options unless process.platform is 'darwin'
    paths = process.env.PATH.split(':')

    # NB: Atom Shell's build process requires PyObjC, which is part of system Python,
    # but not part of the Python installed by Homebrew. If the default Python is
    # the Homebrew one, we need to rig PATH to point to the good one
    pyPath = _.find paths, (x) -> fs.existsSync(path.join(x, 'python'))
    return options if pyPath is '/usr/bin'

    newEnv = _.extend {}, process.env

    ret = _.extend {}, options
    ret.opts ?= {}
    ret.opts.env ?= newEnv
    ret.opts.env.PATH = '/usr/bin:' + process.env.PATH

    ret.cmd = '/usr/bin/python' if ret.cmd is 'python'
    ret

  spawnObservable = (options={}) ->
    fixedOpts = fixBorkedOSXPythonPath(options)

    rx.Observable.create (subj) ->
      grunt.verbose.ok "Running: #{options.cmd} #{options.args.join ' '}"

      spawn fixedOpts, (error, result, code) ->
        if error
          subj.onError error
          return

        subj.onNext {error,result,code}
        subj.onCompleted()

      rx.Disposable.empty
      
  stripAllBinaries = (dirToStrip) ->
    if process.platform is 'win32'
      return rx.Observable.create (subj) ->
        symFiles = /\.(pdb|ilk|exp)$/i
        toDelete = _.filter glob.sync(path.join(dirToStrip, '**')), (x) -> x.match(symFiles)

        grunt.verbose.ok "Stripping symbols: #{toDelete.join(',')}"
        _.each toDelete, (x) -> rm(x)
        return rx.Observable.return(true).subscribe(subj)
    
    binaryFiles = /\.(so|dylib|node)$/i

    return rx.Observable.create((subj) ->
      grunt.verbose.ok "Stripping all binaries"
      
      binaries = _.filter(glob.sync(path.join(dirToStrip, '**')), (x) ->
        return true if x.match(binaryFiles)
        stat = fs.lstatSync(x)

        return false if stat.isSymbolicLink()
        
        # Check if executable bit is set
        return stat and stat.isFile() and (stat.mode & 0o111) > 0
      )

      unless binaries and binaries.length > 0
        grunt.verbose.ok "Nothing to strip!"
        return rx.Observable.return(true).subscribe(subj)
      
      grunt.verbose.ok "Stripping binaries: #{binaries.join(',')}"

      return rx.Observable.fromArray(binaries)
        .flatMap((x) -> spawnObservable({cmd: 'strip', args: [x], opts: {cwd: dirToStrip }}).catch(rx.Observable.return(true)))
        .takeLast(1)
        .subscribe(subj)
    )

  bootstrapAtomShell = (buildDir, atomShellDir, remoteUrl, tag, stdout, stderr) ->
    cmds = [
      { cmd: 'git', args: ['fetch', 'origin'], opts: {cwd: atomShellDir}, stdout: stdout, stderr: stderr },
      { cmd: 'git', args: ['reset', '--hard', 'HEAD'], opts: {cwd: atomShellDir}, stdout: stdout, stderr: stderr },
      { cmd: 'git', args: ['checkout', tag, ], opts: {cwd: atomShellDir}, stdout: stdout, stderr: stderr },
    ]

    if fs.existsSync(atomShellDir)
      cmds.unshift { cmd: 'git', args: ['remote', 'set-url', 'origin', remoteUrl], opts: {cwd: atomShellDir} },
    else
      rm atomShellDir

      grunt.verbose.ok "Cloning to #{buildDir}"
      grunt.file.mkdir buildDir
      cmds.unshift { cmd: 'git', args: ['clone', remoteUrl, 'atom-shell'], opts: {cwd: buildDir} },

    bootstrapAtomShell = rx.Observable.fromArray(cmds)
      .concatMap (x) -> spawnObservable(x)
      .takeLast(1)

  envWithGypDefines = (projectName, productName) ->
    ewg = _.extend {}, process.env
    ewg.GYP_DEFINES = "project_name=#{projectName} product_name=#{productName.replace(' ','\\ ')}"
    if process.env.GYP_DEFINES?
      ewg.GYP_DEFINES = "#{process.env.GYP_DEFINES} #{ewg.GYP_DEFINES}"
    ewg

  buildAtomShell = (atomShellDir, config, projectName, productName, forceRebuild, stdout, stderr, arch) ->
    cmdOptions =
      cwd: atomShellDir
      env: envWithGypDefines(projectName, productName)

    bootstrapCmd =
      cmd: 'python'
      args: ['script/bootstrap.py', '-v', '-y']
      opts: cmdOptions
      stdout: stdout
      stderr: stderr

    buildCmd =
      cmd: 'python'
      args: ['script/build.py', '-c', config, '-t', projectName]
      opts: cmdOptions
      stdout: stdout
      stderr: stderr

    if arch
      bootstrapCmd.args.push '--target_arch'
      bootstrapCmd.args.push arch

    rx.Observable.create (subj) ->
      grunt.verbose.ok "Rigging atom.gyp to have correct name"
      gypFile = path.join(atomShellDir, 'atom.gyp')
      atomGyp = grunt.file.read gypFile
      atomGyp = atomGyp
        .replace("'project_name': 'atom'", "'project_name': '#{projectName}'")
        .replace("'product_name': 'Atom'", "'product_name': '#{productName}'")
        .replace("'framework_name': 'Atom Framework'", "'framework_name': '#{productName} Framework'")
        .replace("'<(project_name) Framework'", "'<(product_name) Framework'") # fix upstream typo in 0.20.3

      grunt.file.write gypFile, atomGyp

      canary = path.join(atomShellDir, 'vendor', 'brightray', 'vendor', 'libchromiumcontent', 'VERSION')
      outDir = path.join(atomShellDir, 'out', 'R')

      bootstrap = spawnObservable(bootstrapCmd)
      if fs.existsSync(canary) and fs.existsSync(outDir) and (not forceRebuild?)
        grunt.verbose.ok("bootstrap appears to have been run, skipping it to save time!")
        bootstrap = rx.Observable.return(true)

      rx.Observable.concat(bootstrap, spawnObservable(buildCmd), stripAllBinaries(outDir))
        .takeLast(1)
        .subscribe(subj)

  generateNodeLib = (atomShellDir, config, projectName, forceRebuild, nodeVersion, stdout, stderr, arch) ->
    return rx.Observable.return(true) unless process.platform is 'win32'

    homeDir = if process.platform is 'win32' then process.env.USERPROFILE else process.env.HOME
    atomHome = process.env.ATOM_HOME ? path.join(homeDir, ".#{projectName}")
    nodeGypHome =  path.join(atomHome, '.node-gyp')

    rx.Observable.create (subj) ->
      source = path.resolve atomShellDir, 'out', 'R', 'node.dll.lib'
      target = path.resolve nodeGypHome, '.node-gyp', nodeVersion, arch ? 'ia32', 'node.lib'

      grunt.verbose.ok 'Copying new node.lib'
      if fs.existsSync(source) and (not forceRebuild?)
        grunt.verbose.ok 'Found existing node.lib, reusing it'
        cp source, target
        return rx.Observable.return(true).subscribe(subj)

      buildNodeLib =
        cmd: 'python'
        args: ['script/build.py', '-c', config, '-t', 'generate_node_lib']
        opts: { cwd: atomShellDir }
        stdout: stdout
        stderr: stderr

      rx.Observable.return(true).do(-> cp source, target).subscribe(subj)

  installNode = (projectName, nodeVersion, stdout, stderr, arch) ->
    nodeArch = arch ? switch process.platform
      when 'darwin' then 'x64'
      when 'win32' then 'ia32'
      else process.arch

    homeDir = if process.platform is 'win32' then process.env.USERPROFILE else process.env.HOME
    atomHome = process.env.ATOM_HOME ? path.join(homeDir, ".#{projectName}")
    nodeGypHome =  path.join(atomHome, '.node-gyp')
    distUrl = process.env.ATOM_NODE_URL ? 'https://gh-contractor-zcbenz.s3.amazonaws.com/atom-shell/dist'

    canary = path.join(nodeGypHome, '.node-gyp', nodeVersion, 'common.gypi')
    if (fs.existsSync(canary))
      return rx.Observable.create (subj) ->
        grunt.verbose.ok 'Found existing node.js installation, skipping install to save time!'
        rx.Observable.return(true).subscribe(subj)

    cmd = 'node'
    args = [require.resolve('npm/node_modules/node-gyp/bin/node-gyp'), 'install',
      "--target=#{nodeVersion}",
      "--arch=#{nodeArch}",
      "--dist-url=#{distUrl}"]

    env = _.extend {}, process.env, HOME: nodeGypHome
    env.USERPROFILE = env.HOME if process.platform is 'win32'

    rx.Observable.create (subj) ->
      grunt.verbose.ok 'Installing node.js'
      spawnObservable({cmd, args, opts: {env}, stdout: stdout, stderr: stderr}).subscribe(subj)

  rebuildNativeModules = (projectName, nodeVersion, stdout, stderr, arch) ->
    nodeArch = arch ? switch process.platform
      when 'darwin' then 'x64'
      when 'win32' then 'ia32'
      else process.arch

    homeDir = if process.platform is 'win32' then process.env.USERPROFILE else process.env.HOME
    atomHome = process.env.ATOM_HOME ? path.join(homeDir, ".#{projectName}")
    nodeGypHome =  path.join(atomHome, '.node-gyp')

    cmd = 'node'
    args = [require.resolve('npm/bin/npm-cli'), 'rebuild', "--target=#{nodeVersion}", "--arch=#{nodeArch}"]
    env = _.extend {}, process.env, HOME: nodeGypHome
    env.USERPROFILE = env.HOME if process.platform is 'win32'

    rx.Observable.create (subj) ->
      grunt.verbose.ok 'Rebuilding native modules against Atom Shell'
      
      spawnObservable({cmd, args, opts: {env}, stdout: stdout, stderr: stderr})
        .concat(stripAllBinaries('../node_modules'))
        .subscribe(subj)

  grunt.registerTask 'rebuild-native-modules', "Rebuild native modules (debugging)", ->
    done = @async()

    {buildDir, config, projectName, nodeVersion, stdout, stderr, arch}  = grunt.config 'build-atom-shell'
    config ?= 'Release'
    atomShellDir = path.join buildDir, 'atom-shell'

    rebuild = rx.Observable.concat(
      installNode(projectName, nodeVersion, stdout, stderr, arch),
      generateNodeLib(atomShellDir, config, projectName, true, nodeVersion, stdout, stderr, arch),
      rebuildNativeModules(projectName, nodeVersion, stdout, stderr, arch)).takeLast(1)

    rebuild.subscribe(done, done)

  grunt.registerTask 'rebuild-atom-shell', 'Clean build Atom Shell', ->
    @requiresConfig "build-atom-shell.buildDir"

    {buildDir} = grunt.config 'build-atom-shell'
    atomShellDir = path.join buildDir, 'atom-shell'
    rm atomShellDir

    grunt.task.run 'build-atom-shell'

  grunt.registerTask 'build-atom-shell', 'Build Atom Shell from source', ->
    done = @async()

    @requiresConfig "#{@name}.buildDir", "#{@name}.tag", "#{@name}.projectName", "#{@name}.productName"

    {buildDir, targetDir, config, remoteUrl, projectName, productName, tag, forceRebuild, nodeVersion, arch, stdout, stderr} = grunt.config @name
    config ?= 'Release'
    remoteUrl ?= 'https://github.com/atom/atom-shell'
    targetDir ?= 'atom-shell'
    atomShellDir = path.join buildDir, 'atom-shell'
    nodeVersion ?= process.env.ATOM_NODE_VERSION ? '0.20.0'

    buildAndTryBootstrappingIfItDoesntWork =
      buildAtomShell(atomShellDir, config, projectName, productName, forceRebuild, stdout, stderr, arch)
        .catch(buildAtomShell(atomShellDir, config, projectName, productName, true, stdout, stderr, arch))

    buildErrything = rx.Observable.concat(
      bootstrapAtomShell(buildDir, atomShellDir, remoteUrl, tag, stdout, stderr),
      buildAndTryBootstrappingIfItDoesntWork,
      installNode(projectName, nodeVersion, stdout, stderr, arch),
      generateNodeLib(atomShellDir, config, projectName, forceRebuild, nodeVersion, stdout, stderr, arch),
      rebuildNativeModules(projectName, nodeVersion, stdout, stderr, arch)).takeLast(1)

    buildErrything
      .map (x) ->
        rm targetDir
        cp(path.resolve(atomShellDir, 'out', config.slice(0,1)), targetDir)
        return x
      .subscribe(( ->), done, done)
