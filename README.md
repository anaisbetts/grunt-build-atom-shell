# grunt-build-atom-shell

Build atom-shell from Git, and rebuild native modules. This is a mostly drop-in replacement for `grunt-download-atom-shell`, in that, you can replace your use of it with this package at the same point in the Atom build process and everything should Just Work.

## Why even would I do this?

The main reason to do this is because of [atom/atom-shell#713](https://github.com/atom/atom-shell/issues/713) - trying to rename Atom after-the-fact isn't possible on Windows without some serious rigging. This package fixes that issue, as well as allows you to use arbitrary builds of Atom Shell (i.e. no more waiting for a new release for a bugfix). 

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
