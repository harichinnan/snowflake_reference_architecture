/* =============================================================================
   001_create_roles.sql
   snowflake-claims-platform :: Role hierarchy & access control bootstrap
   -----------------------------------------------------------------------------
   100% Snowflake-only reference architecture (synthetic claims data).
   NOTE: All data in this platform is SYNTHETIC. There is NO real PHI/PII.
         The role model below still mirrors a real HIPAA-grade least-privilege
         design so the patterns are production-faithful.

   WHAT THIS SCRIPT DOES
     - Creates 7 functional/custom roles.
     - Wires a role hierarchy that follows Snowflake best practice:
         * Functional roles roll UP into a single object-owning admin role
           (CLAIMS_SYSADMIN), which rolls up into the built-in SYSADMIN.
         * The security/governance role (CLAIMS_SECURITY_ADMIN) rolls up into
           the built-in SECURITYADMIN (NOT into SYSADMIN) to keep
           "who manages data" separate from "who manages access".
     - Grants the relevant roles to a deployment/service user placeholder.

   PRINCIPLES APPLIED
     - LEAST PRIVILEGE: each functional role gets only what its job needs.
       (Object grants live in later scripts; here we only build the tree.)
     - SEPARATION OF DUTIES (SoD): the role that LOADS data is not the role
       that TRANSFORMS it, which is not the role that READS it. The role that
       manages SECURITY/GRANTS is fully separate from the role that owns DATA
       OBJECTS. This prevents a single compromised role from both writing data
       and granting itself access.
     - ROLE HIERARCHY: privileges flow UPWARD. Granting role A to role B means
       B inherits A. We grant functional roles to CLAIMS_SYSADMIN so an admin
       can act as any functional role, and CLAIMS_SYSADMIN to SYSADMIN so the
       global sysadmin retains visibility.

   RUN AS: ACCOUNTADMIN (role creation + grants to built-in roles).
   IDEMPOTENT: CREATE ROLE IF NOT EXISTS + GRANT statements are safe to re-run.
   ============================================================================= */

USE ROLE ACCOUNTADMIN;

-- Role management is conventionally done by SECURITYADMIN/USERADMIN; we use
-- ACCOUNTADMIN here only because this is the very first bootstrap script and
-- we also need to grant into the built-in SYSADMIN/SECURITYADMIN hierarchy.

/* -----------------------------------------------------------------------------
   1. CREATE THE 7 CUSTOM ROLES
   -----------------------------------------------------------------------------
   CLAIMS_SYSADMIN        : Owns all CLAIMS_* databases/schemas/objects created
                            by these setup scripts. The "object owner" admin.
   CLAIMS_LOADER          : Can write to RAW/BRONZE landing (COPY INTO, stages).
                            Cannot transform or read curated GOLD.
   CLAIMS_TRANSFORMER     : Runs dbt transformations (BRONZE->SILVER->GOLD).
                            Read RAW/BRONZE, write SILVER/GOLD. The dbt service
                            role in CI uses this.
   CLAIMS_ANALYST         : Read-only on GOLD/SEMANTIC. The human BI consumer.
   CLAIMS_CI              : CI/CD automation (GitHub Actions) deploy + dbt build.
                            Operationally powerful but scoped to the platform DB.
   CLAIMS_MCP_READER      : The narrow read-only surface exposed to the
                            Snowflake-managed MCP server / Cortex Agent. SELECT
                            only on approved GOLD/SEMANTIC/MCP_* views.
   CLAIMS_SECURITY_ADMIN  : Manages masking/row-access policies, tags, grants,
                            future-grants. Governance. Rolls into SECURITYADMIN.
   --------------------------------------------------------------------------- */

CREATE ROLE IF NOT EXISTS CLAIMS_SYSADMIN
  COMMENT = 'Owns all CLAIMS_* objects. Object-admin for the claims platform. Rolls up to SYSADMIN.';

CREATE ROLE IF NOT EXISTS CLAIMS_LOADER
  COMMENT = 'Ingestion role. Writes to RAW/BRONZE landing via stages + COPY INTO. No transform, no curated read.';

CREATE ROLE IF NOT EXISTS CLAIMS_TRANSFORMER
  COMMENT = 'dbt transformation role. Reads RAW/BRONZE, builds SILVER/GOLD. Used by dbt in CI.';

CREATE ROLE IF NOT EXISTS CLAIMS_ANALYST
  COMMENT = 'Read-only analytics consumer. SELECT on GOLD + SEMANTIC only.';

CREATE ROLE IF NOT EXISTS CLAIMS_CI
  COMMENT = 'CI/CD automation role (GitHub Actions). Deploys platform objects and runs dbt build.';

CREATE ROLE IF NOT EXISTS CLAIMS_MCP_READER
  COMMENT = 'Narrow read-only role exposed to Snowflake-managed MCP / Cortex Agent. SELECT on approved views only.';

CREATE ROLE IF NOT EXISTS CLAIMS_SECURITY_ADMIN
  COMMENT = 'Governance role. Manages policies, tags, grants. Rolls up to SECURITYADMIN (SoD: separate from data ownership).';

/* -----------------------------------------------------------------------------
   2. BUILD THE ROLE HIERARCHY
   -----------------------------------------------------------------------------
   Reminder on Snowflake semantics: `GRANT ROLE child TO ROLE parent` means the
   PARENT inherits all privileges of the CHILD. So to let CLAIMS_SYSADMIN "be"
   any functional role, we grant the functional roles TO CLAIMS_SYSADMIN.

       SYSADMIN
         └── CLAIMS_SYSADMIN
               ├── CLAIMS_LOADER
               ├── CLAIMS_TRANSFORMER
               ├── CLAIMS_ANALYST
               ├── CLAIMS_CI
               └── CLAIMS_MCP_READER

       SECURITYADMIN
         └── CLAIMS_SECURITY_ADMIN

   We deliberately do NOT roll CLAIMS_SECURITY_ADMIN into CLAIMS_SYSADMIN: a
   data-object owner should not silently inherit the ability to rewrite access
   policies. That is the separation-of-duties boundary.
   --------------------------------------------------------------------------- */

-- Functional roles -> CLAIMS_SYSADMIN
GRANT ROLE CLAIMS_LOADER       TO ROLE CLAIMS_SYSADMIN;
GRANT ROLE CLAIMS_TRANSFORMER  TO ROLE CLAIMS_SYSADMIN;
GRANT ROLE CLAIMS_ANALYST      TO ROLE CLAIMS_SYSADMIN;
GRANT ROLE CLAIMS_CI           TO ROLE CLAIMS_SYSADMIN;
GRANT ROLE CLAIMS_MCP_READER   TO ROLE CLAIMS_SYSADMIN;

-- CLAIMS_SYSADMIN -> built-in SYSADMIN (keeps global sysadmin in the loop)
GRANT ROLE CLAIMS_SYSADMIN     TO ROLE SYSADMIN;

-- Security/governance role -> built-in SECURITYADMIN (SoD boundary)
GRANT ROLE CLAIMS_SECURITY_ADMIN TO ROLE SECURITYADMIN;

/* -----------------------------------------------------------------------------
   3. GRANT ROLES TO A DEPLOYMENT USER PLACEHOLDER
   -----------------------------------------------------------------------------
   Replace CLAIMS_DEPLOY_USER with your real deployment principal (a service
   user authenticating with an RSA key pair in CI, NOT a password). The CI
   pipeline assumes CLAIMS_CI for deploys; an operator may also assume
   CLAIMS_SYSADMIN. We guard the grants so the script does not fail if the
   placeholder user has not been created yet.

   PRODUCTION GUIDANCE
     - Use key-pair auth (no passwords) for service users.
     - Set a DEFAULT_ROLE explicitly so unqualified sessions are least-priv.
     - Never grant ACCOUNTADMIN to automation. CLAIMS_CI is the ceiling for CI.
   --------------------------------------------------------------------------- */

-- Example (uncomment + set RSA_PUBLIC_KEY when provisioning the real user):
-- CREATE USER IF NOT EXISTS CLAIMS_DEPLOY_USER
--   DEFAULT_ROLE = CLAIMS_CI
--   DEFAULT_WAREHOUSE = WH_CLAIMS_CI
--   MUST_CHANGE_PASSWORD = FALSE
--   COMMENT = 'CI/CD deployment service user (key-pair auth).';
-- ALTER USER CLAIMS_DEPLOY_USER SET RSA_PUBLIC_KEY = '<BASE64_DER_PUBLIC_KEY>';

-- Grants are wrapped so a missing placeholder user does not abort the run.
EXECUTE IMMEDIATE $$
BEGIN
  GRANT ROLE CLAIMS_CI         TO USER CLAIMS_DEPLOY_USER;
  GRANT ROLE CLAIMS_SYSADMIN   TO USER CLAIMS_DEPLOY_USER;
EXCEPTION
  WHEN OTHER THEN
    -- Placeholder user likely does not exist yet; safe to ignore in bootstrap.
    SYSTEM$LOG('info', 'CLAIMS_DEPLOY_USER not present yet; skip user grants.');
END;
$$;

-- Also let the human running setup adopt the platform admin role conveniently.
-- (Uses the session user; harmless and idempotent.)
EXECUTE IMMEDIATE $$
BEGIN
  GRANT ROLE CLAIMS_SYSADMIN      TO USER IDENTIFIER(CURRENT_USER());
  GRANT ROLE CLAIMS_SECURITY_ADMIN TO USER IDENTIFIER(CURRENT_USER());
EXCEPTION
  WHEN OTHER THEN
    SYSTEM$LOG('info', 'Could not self-grant claims roles to current user; continuing.');
END;
$$;

/* -----------------------------------------------------------------------------
   DONE. Object-level grants (warehouse usage, schema privileges, future grants)
   are applied in scripts 002+ so they live next to the objects they protect.
   --------------------------------------------------------------------------- */
