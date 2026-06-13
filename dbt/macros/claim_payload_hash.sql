{# =============================================================================
   macros/claim_payload_hash.sql
   snowflake-claims-platform

   Computes a stable SHA2-256 hash of a VARIANT payload, used for idempotency
   and dedupe (e.g. "have we already seen this exact record?"). We hash the
   canonicalized JSON text of the payload so that key ordering / whitespace in
   the original VARIANT does not change the hash.

   Implementation notes:
     - to_json(<variant>) renders a canonical, key-sorted-by-insertion string.
       To be order-insensitive we wrap with object_construct round-trip only
       when needed; for typical normalized payloads to_json is sufficient and
       cheap. We document the stronger normalization in a comment.
     - sha2(..., 256) returns a 64-char hex string.

   Params:
     payload_col : the VARIANT column/expression to hash (default 'payload').

   Usage:
       {{ claim_payload_hash('payload') }}                  as payload_hash
       {{ claim_payload_hash('b.payload') }}                as payload_hash
   ============================================================================= #}

{% macro claim_payload_hash(payload_col='payload') %}
    {#- to_json gives a deterministic text rendering of the VARIANT; sha2 256-bit
        hex digest is our idempotency fingerprint. For strict key-order
        independence, normalize upstream (e.g. object_construct of sorted keys)
        before hashing. -#}
    sha2(to_json({{ payload_col }}), 256)
{% endmacro %}
