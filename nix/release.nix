{ lib, beam, coreutils, src }:
let
  # Explicit source selection keeps local credentials and development artifacts
  # out of both the dependency fetch and the final release's store closure.
  source = lib.fileset.toSource {
    root = src;
    fileset = lib.fileset.intersection
      (if builtins.pathExists (src + /.git) then lib.fileset.gitTracked src else src)
      (lib.fileset.unions [
      (src + /mix.exs)
      (src + /mix.lock)
      (src + /config)
      (src + /lib)
      (src + /priv)
      ]);
  };
in (beam.mixRelease {
  pname = "emailjanitor";
  version = "0.1.0-dev";
  src = source;
  mixFodDeps = beam.fetchMixDeps {
    pname = "emailjanitor-deps";
    version = "0.1.0-dev";
    src = source;
    hash = "sha256-C+9t3kx9eiKrLlS1f7Se5dg+sY6qM7KxSGx2DvHehzk=";
  };
  meta = {
    description = "Single-user Email Janitor Elixir release";
    license = lib.licenses.mit;
    mainProgram = "email_janitor";
    platforms = lib.platforms.unix;
  };
}).overrideAttrs (old: {
  # The pinned builder owns postFixup, so append after it through overrideAttrs.
  # No shared cookie is embedded and distributed Erlang is always disabled.
  postFixup = old.postFixup + ''
    wrapProgram "$out/bin/email_janitor" \
      --set RELEASE_DISTRIBUTION none \
      --run 'export RELEASE_COOKIE="$(${coreutils}/bin/head -c 32 /dev/urandom | ${coreutils}/bin/base64)"'
  '';
})
