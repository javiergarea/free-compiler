# Haskell To Coq Compiler

A compiler for the monadic translation of Haskell programs to Coq that uses the `Free` monad as presented by [Dylus et al.](https://arxiv.org/abs/1805.08059) to model partiality and other ambient effects.

## Documentation

-   [Thesis](https://thesis.ba.just-otter.com)
-   [Haddock documentation](https://haskell-to-coq-compiler.just-otter.com)

## Required Software

The Haskell to Coq compiler is written in Haskell and uses Cabal to manage its dependencies.
To build the compiler, the GHC and Cabal are required.
To use the Coq code generated by our compiler, the Coq proof assistant must be installed.
The compiler has been tested with the following software versions on a Debian based operating system.

-   [GHC](https://www.haskell.org/ghc/), version 8.6.5
-   [Cabal](https://www.haskell.org/cabal/), version 2.4.1.0
-   [Coq](https://coq.inria.fr/download), version 8.8.2

## Compiling the Base Library

In order to use the base library, the Coq files in the base library need to be compiled first.
Make sure to compile the base library before installing the compiler.
We provide a shell script for the compilation of Coq files.
To compile the base library with that shell script, run the following command in the root directory of the compiler.

```bash
./tool/compile-coq.sh base
```

## Installation

First, make sure that the Cabal package lists are up to date  by running the following command.

```bash
cabal new-update
```

To build and install the compiler and its dependencies, change into the compiler’s root directory and run the following command.

```bash
cabal new-install haskell-to-coq-compiler
```

The command above copies the base library and the compiler’s executable to Cabal’s installation directory and creates a symbolic link to the executable in
`~/.cabal/bin`.
To test whether the installation was successful, make sure that `~/.cabal/bin` is in your `PATH` environment variable and run the following command.

```bash
haskell-to-coq-compiler --help
```

## Running without Installation

If you want to run the compiler without installing it on your machine (i.e., for debugging purposes), execute the following command in the root directory of the compiler instead of the `haskell-to-coq-compiler` command.

```bash
cabal new-run haskell-to-coq-compiler -- [options...] <input-files...>
```

The two dashes are needed to separate the arguments to pass to the compiler from Cabal’s arguments.
Alternatively, you can use the `./tool/run.sh` bash script.

```bash
./tool/run.sh [options...] <input-files...>
```

## Usage

To compile a Haskell module, pass the file name of the module to `haskell-to-coq-compiler`.
For example, to compile the queue example module run the following command.

```bash
haskell-to-coq-compiler ./example/ExampleQueue.hs
```

The generated Coq code is printed to the console. To write the generated Coq code into a file, specify the output directory using the `--output` (or `-o`) option. For example, the following command creates a file
`example/generated/ExampleQueue.v`.

```bash
haskell-to-coq-compiler -o ./example/generated ./example/ExampleQueue.hs
```

In addition to the Coq file, a `_CoqProject` file is created in the output directory if it does not exist already. The `_CoqProject` file tells Coq where to find the compiler’s base library. Add the `--no-coq-project` command line flag to disable the generation of a `_CoqProject` file.

In order to compile Haskell modules successfully, the compiler needs to know the names of predefined data types and operations. For this purpose, the `base/env.toml` configuration file has to be loaded.
If the compiler is installed as described above, it will be able to locate the base library automatically.
Otherwise, it may be necessary to tell the compiler where the base library can be found using the `--base-library` (or `-b`) option.

Use the `--help` (or `-h`) option for more details on supported command line options.

## Experimental Features

### Pattern-Matching Compilation

By default the compiler does support a limited subset of the Haskell programming language only.
There is experimental support to relax some of those restrictions.
Add the `--transform-pattern-matching` command line option to enable the translation of function declarations with multiple rules and guards.
The Haskell to Coq compiler uses a slightly [adapted version](https://git.informatik.uni-kiel.de/stu203400/haskell-code-transformation) of the [pattern matching compiler](https://git.informatik.uni-kiel.de/stu204333/placc-thesis) developed by [Malte Clement](https://git.informatik.uni-kiel.de/stu204333).
Note that if pattern matching compilation is enabled, error messages will not contain any location information.

##### Example

```bash
haskell-to-coq-compiler --transform-pattern-matching -o ./example/generated ./example/Hutton.hs
```
