# Nim 2.2.14 on top of nixpkgs' 2.2.4, as logos-storage-nim does. 2.2.10 has a
# refc heap-corruption bug (Nim#25992), so nothing older than 2.2.14.
final: prev: {
  nim-unwrapped-2_2 = prev.nim-unwrapped-2_2.overrideAttrs (old: rec {
    version = "2.2.14";
    src = prev.fetchurl {
      url = "https://nim-lang.org/download/nim-${version}.tar.xz";
      hash = "sha256-iSc/g/I3lGX0lMgnHv46Y82eeJITCLhHP0/+1TjbtTY=";
    };
    # Neither patch applies to 2.2.14; openssl.patch only changes how
    # std/openssl loads libssl, which nothing here imports.
    patches = builtins.filter (
      p:
      !(builtins.elem (baseNameOf (toString p)) [
        "extra-mangling-2.patch"
        "openssl.patch"
      ])
    ) old.patches;
    # 2.2.10 and later no longer compile with this flag.
    kochArgs = builtins.filter (f: f != "-d:nativeStacktrace") old.kochArgs;
  });
}
