import assert from "node:assert/strict";
import { resolve } from "node:path";
import test from "node:test";
import { ROOT, expectExit, run } from "./helpers.mjs";

const HELPER = resolve(ROOT, "git-credential-ghtoken");
const REQUEST = "protocol=https\nhost=github.com\n\n";

test("credential helper serves a plain token only to github.com", () => {
  const result = run(HELPER, ["get"], {
    env: { GH_TOKEN: "plain-token" },
    input: REQUEST,
  });
  expectExit(result, 0, "credential get");
  assert.equal(result.stdout, "username=x-access-token\npassword=plain-token\n");

  const other = run(HELPER, ["get"], {
    env: { GH_TOKEN: "plain-token" },
    input: "protocol=https\nhost=example.com\n\n",
  });
  expectExit(other, 0, "non-GitHub credential get");
  assert.equal(other.stdout, "");
});

test("credential helper rejects CR/LF-bearing tokens", () => {
  for (const token of ["line1\nline2", "line1\rline2", "line1\r\nline2"]) {
    const result = run(HELPER, ["get"], {
      env: { GH_TOKEN: token },
      input: REQUEST,
    });
    expectExit(result, 0, "unsafe token refusal");
    assert.equal(result.stdout, "");
  }
});
