//! Shared browser policies and the script authorized by the generated CSP hash.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const theme_script = @embedFile("theme.js");

const theme_hash = hash: {
    // Hash the embedded script once at compilation, for both HTML and HTTP headers.
    @setEvalBranchQuota(100_000);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(theme_script, &digest, .{});
    var encoded: [std.base64.standard.Encoder.calcSize(digest.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, &digest);
    break :hash encoded;
};

pub const meta_content_security_policy =
    "default-src 'self'; script-src 'self' 'sha256-" ++ theme_hash ++ "';";

// frame-ancestors is enforced only in response headers, not in a meta element.
pub const content_security_policy = meta_content_security_policy ++
    " object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'self';";

pub const referrer_policy = "strict-origin";
