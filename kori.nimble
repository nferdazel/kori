version     = "0.10.0"
author      = "Team C"
description = "kori — in-house LLM provider gateway"
license     = "MIT"
srcDir      = "apps/api/src"
bin         = @["kori"]

requires "nim >= 2.0.0"

task test, "Run the slice-1 unit tests":
  # -d:ssl because the unit test imports the gateway module, whose TLS path is
  # compiled in; the project directory (tests/unit) has no config.nims of its own.
  exec "nim c -r -d:ssl --hints:off --mm:orc --threads:on --out:out/test-kori tests/unit/test_kori.nim"
