# Copyright (C) 2004 - 2005 John Goerzen <jgoerzen@complete.org>
#
#    This library is free software; you can redistribute it and/or
#    modify it under the terms of the GNU Lesser General Public
#    License as published by the Free Software Foundation; either
#    version 2.1 of the License, or (at your option) any later version.
#
#    This library is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
#    Lesser General Public License for more details.
#
#    You should have received a copy of the GNU Lesser General Public
#    License along with this library; if not, write to the Free Software
#    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

GHCPARMS := -fglasgow-exts

.PHONY: all hugsbuild
all: setup			# GHC build
	./setup configure --user
	./setup build

hugsbuild: setup
	./setup configure --hugs
	./setup build

setup: Setup.lhs HDBC-sqlite3.cabal
	ghc -package Cabal Setup.lhs -o setup

clean:
	-./setup clean
	-rm -rf html `find . -name "*.o"` `find . -name "*.hi" | grep -v debian` \
		`find . -name "*~" | grep -v debian` *.a setup dist testsrc/runtests \
		local-pkg doctmp
	-rm -rf testtmp/* testtmp*

testsrc/runtests: all $(wildcard testsrc/*.hs) $(wildcard testsrc/*/*.hs) $(wildcard testsrc/*/*/*.hs)
	cd testsrc && ghc --make -package mtl -package HUnit -package MissingH -package HDBC -lsqlite3 ../dist/build/hdbc-sqlite3-helper.o $(GHCPARMS) -o runtests  -i../dist/build:.. runtests.hs

test-ghc6: testsrc/runtests
	testsrc/runtests

test-hugs: hugsbuild
	runhugs -98 +o -P$(PWD)/dist/build:$(PWD)/testsrc: testsrc/runtests.hs

interact-hugs:
	hugs -98 +o -P$(PWD)/dist/build:

interact-ghci: all
	ghci -idist/build -Ldist/build $(GHCPARMS)

interact: interact-hugs

test: test-ghc6 test-hugs

