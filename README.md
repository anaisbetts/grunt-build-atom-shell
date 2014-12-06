# grunt-build-atom-shell

Build atom-shell from Git, and rebuild native modules

## Installation

Install npm package, next to your project's `Gruntfile.js` file:

```sh
npm install --save-dev grunt-build-atom-shell
```

Add this line to your project's `Gruntfile.js`:

```js
grunt.loadNpmTasks('grunt-build-atom-shell');
```

## Options

* `buildDir` - **Required** Where to put the downloaded atom-shell
* `tag` - **Required** A tag, branch, or commit of Atom Shell to build
* `projectName` - **Required** A short name for your project (originally 'atom')
* `productName` - **Required** The name of the final binary generated (originally 'Atom')
* `config` - Either 'Debug' or 'Release', defaults to 'Release'
* `remoteUrl` - The Git remote url to download from, defaults to official Atom Shell

### Example

#### Gruntfile.js

```js
module.exports = function(grunt) {
  grunt.initConfig({
    'build-atom-shell': {
      tag: 'v0.16.3',
      buildDir: 'atom-shell',
      projectName: 'mycoolapp',
      productName: 'MyCoolApp'
    }
  });
};
```
