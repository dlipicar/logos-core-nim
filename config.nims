# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

switch("styleCheck", "usages")
switch("styleCheck", "error")
switch("hint", "XDeclaredButNotUsed:off")
