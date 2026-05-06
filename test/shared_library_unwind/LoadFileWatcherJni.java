// Copyright 2000-2026 JetBrains s.r.o. and contributors. Use of this source code is governed by the Apache 2.0 license.
package com.jetbrains.analyzer.filewatcher.repro;

import com.google.devtools.build.runfiles.Runfiles;

import java.io.IOException;
import java.nio.file.Path;

public final class LoadFileWatcherJni {
  private LoadFileWatcherJni() {
  }

  public static void main(String[] args) throws IOException {
    if (args.length != 1) {
      throw new IllegalArgumentException("Expected one runfiles path to libfilewatcher_jni.so");
    }

    String library = Runfiles.preload().unmapped().rlocation(args[0]);
    if (library == null) {
      throw new IllegalStateException("Could not resolve runfile: " + args[0]);
    }

    Path libraryPath = Path.of(library).toAbsolutePath();
    System.err.println("System.load(" + libraryPath + ")");
    System.load(libraryPath.toString());
    System.out.println("Loaded " + libraryPath);
  }
}
