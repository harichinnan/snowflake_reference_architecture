#!/usr/bin/env python3
# =============================================================================
#  ____  _____ _   _ _____ _   _ _____ _____ ___ ____   _____ ____ _____ _____
# / ___||  _  | \ | |_   _| | | | ____|_   _|_ _/ ___| |_   _|  __|_   _| ____|
# \___ \| | | |  \| | | | | |_| |  _|   | |  | | |       | | |  _|  | | |  _|
#  ___) | |_| | |\  | | | |  _  | |___  | |  | | |___    | | | |___ | | | |___
# |____/ \___/|_| \_| |_| |_| |_|_____| |_| |___\____|   |_| |_____||_| |_____|
#
#  ##########################################################################
#  #  100% SYNTHETIC DATA — NOT REAL HEALTHCARE DATA                        #
#  #                                                                        #
#  #  Every identifier, member, provider, NPI, claim, diagnosis, drug and  #
#  #  dollar amount produced by this script is RANDOMLY FABRICATED.         #
#  #                                                                        #
#  #  This is NOT Medicare, NOT Medicaid, NOT CMS RIF, NOT CMS TAF, and     #
#  #  contains NO Protected Health Information (PHI) or PII of any real     #
#  #  person, provider, or payer. NPIs are synthetic 10-digit strings and   #
#  #  do NOT correspond to entries in the real NPPES registry. Any          #
#  #  resemblance to a real entity or claim is purely coincidental.         #
#  #                                                                        #
#  #  Use ONLY for engineering, testing, demos, and pipeline development.   #
#  ##########################################################################
#
# Synthetic Healthcare Claims Data Generator for the snowflake-claims-platform.
#
# Produces newline-delimited JSON (NDJSON) event files modeled after a real
# claims ingestion landing zone. Each line is a self-describing event with a
# bronze-style envelope + a nested payload. The files are intended to be PUT
# to Snowflake internal stages and loaded into bronze (raw) tables, where the
# downstream pipeline is expected to detect and quarantine the malformed rows
# we deliberately inject here.
#
# This generator writes LOCAL NDJSON files. The expected operational flow is:
#     PUT file://output/*.ndjson @<internal_stage>;
#     COPY INTO bronze_<event>_raw FROM @<internal_stage>/...;
#
# Stdlib only (json, random, uuid, hashlib, datetime, argparse, os, pathlib).
# Faker is optional and used ONLY to flavor synthetic names/addresses.
#
# Determinism: all structural randomness derives from random.Random(seed).
# Wall-clock is NOT used for data values. The only "now"-like field,
# file_generation_ts, is supplied via --as-of (default below) so runs are
# byte-for-byte reproducible for a given (seed, args) pair.
# =============================================================================

from __future__ import annotations

import argparse
import hashlib
import json
import os
import uuid
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Optional Faker. Schema/counts/determinism are identical with or without it;
# Faker only changes the flavor of synthetic provider/member names + cities.
# ---------------------------------------------------------------------------
try:
    from faker import Faker  # type: ignore
    _HAVE_FAKER = True
except Exception:  # pragma: no cover - Faker is optional
    Faker = None  # type: ignore
    _HAVE_FAKER = False

# Default "as-of" timestamp for file_generation_ts. Fixed (not wall-clock) so
# output is reproducible. Override with --as-of for a different snapshot.
DEFAULT_AS_OF = "2026-06-13T08:00:00+00:00"

SOURCE_SYSTEM = "SYNTH_CLAIMS_GEN"

# Reference vocabularies (all synthetic / illustrative).
CLAIM_TYPES = ["PROFESSIONAL", "INSTITUTIONAL", "DENTAL", "VISION", "BEHAVIORAL"]
CLAIM_STATUSES = ["PAID", "DENIED", "PENDED", "REVERSED", "VOID"]
PLAN_TYPES = ["HMO", "PPO", "EPO", "POS", "HDHP"]
SPECIALTIES = [
    "Family Medicine", "Internal Medicine", "Cardiology", "Orthopedics",
    "Radiology", "Emergency Medicine", "Pediatrics", "Dermatology",
    "Anesthesiology", "General Surgery",
]
TAXONOMY_CODES = [
    "207Q00000X", "207R00000X", "207RC0000X", "207X00000X", "2085R0202X",
    "207P00000X", "208000000X", "207N00000X", "207L00000X", "208600000X",
]
PROVIDER_TYPES = ["INDIVIDUAL", "ORGANIZATION"]
# Synthetic-looking but structurally valid-ish code vocabularies.
DIAGNOSIS_CODES = ["E11.9", "I10", "J45.909", "M54.5", "Z00.00", "N39.0",
                   "K21.9", "F41.1", "R51.9", "E78.5"]
PROCEDURE_CODES = ["99213", "99214", "93000", "80053", "71046", "20610",
                   "85025", "36415", "90471", "73610"]
REVENUE_CODES = ["0450", "0300", "0250", "0636", "0510", "0420"]
PLACES_OF_SERVICE = ["11", "21", "22", "23", "19", "12"]
DENIAL_REASON_CODES = ["CO-16", "CO-97", "PR-1", "PR-2", "CO-45", "CO-50",
                       "CO-29", "OA-23"]
DRUG_NAMES = ["Synthavil", "Curezol", "Mendapine", "Healixir", "Vitalium",
              "Restomax", "Calmadol", "Clarivex", "Theraline", "Novexa"]
US_STATES = ["CA", "TX", "NY", "FL", "IL", "PA", "OH", "GA", "NC", "MI"]
GENDERS = ["M", "F", "U"]
ADJUSTMENT_REASONS = [
    "CORRECTED_CHARGE", "DUPLICATE_RECOUP", "COB_RECALC",
    "PRICING_UPDATE", "ELIGIBILITY_RETRO", "PROVIDER_REBILL",
]


# ---------------------------------------------------------------------------
# Small deterministic helpers
# ---------------------------------------------------------------------------
def canonical_json(obj) -> str:
    """Canonical JSON: sorted keys, compact separators. Mirrors how bronze
    computes a stable payload_hash for dedupe/change detection."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), default=str)


def payload_hash(payload: dict) -> str:
    """SHA-256 of canonical payload JSON (hex)."""
    return hashlib.sha256(canonical_json(payload).encode("utf-8")).hexdigest()


def det_uuid(rng) -> str:
    """Deterministic UUID4-shaped string from the seeded RNG (NOT uuid4(),
    which would use os entropy and break reproducibility)."""
    return str(uuid.UUID(int=rng.getrandbits(128), version=4))


def iso_dt(d: date, rng) -> str:
    """Turn a date into an ISO-8601 UTC timestamp with a deterministic
    intraday time so business_event_ts values are not all midnight."""
    seconds = rng.randint(0, 86399)
    return (datetime(d.year, d.month, d.day, tzinfo=timezone.utc)
            + timedelta(seconds=seconds)).isoformat()


def d2s(d) -> str:
    """date -> 'YYYY-MM-DD' (None-safe)."""
    return d.isoformat() if isinstance(d, date) else d


def round2(x: float) -> float:
    return round(x + 0.0, 2)


# ---------------------------------------------------------------------------
# Synthetic identity helpers
# ---------------------------------------------------------------------------
class IdFactory:
    """Generates synthetic, clearly-fake identifiers from the seeded RNG."""

    def __init__(self, rng):
        self.rng = rng
        self._npis: list[str] = []

    def member_id(self) -> str:
        return "MBR" + "".join(str(self.rng.randint(0, 9)) for _ in range(9))

    def claim_id(self) -> str:
        return "CLM" + "".join(str(self.rng.randint(0, 9)) for _ in range(11))

    def pharmacy_claim_id(self) -> str:
        return "RX" + "".join(str(self.rng.randint(0, 9)) for _ in range(12))

    def payer_id(self) -> str:
        return "PAYER" + str(self.rng.randint(100, 999))

    def plan_id(self) -> str:
        return "PLN" + str(self.rng.randint(10000, 99999))

    def synthetic_npi(self) -> str:
        """10-digit SYNTHETIC NPI. NOT a real NPPES number. We do NOT compute
        the real Luhn check digit on purpose so these can never collide with
        valid registered NPIs."""
        return "9" + "".join(str(self.rng.randint(0, 9)) for _ in range(9))

    def ndc(self) -> str:
        a = self.rng.randint(10000, 99999)
        b = self.rng.randint(1000, 9999)
        c = self.rng.randint(10, 99)
        return f"{a:05d}-{b:04d}-{c:02d}"

    def provider_pool(self, n: int) -> list[str]:
        """Stable pool of synthetic NPIs reused across providers/claims."""
        if not self._npis:
            self._npis = [self.synthetic_npi() for _ in range(n)]
        return self._npis


# ---------------------------------------------------------------------------
# Envelope builder — common bronze-style metadata wrapper for every event.
# ---------------------------------------------------------------------------
def make_envelope(event_type, source_file_name, source_extract_ts,
                  file_generation_ts, business_event_ts, natural_key, payload,
                  malformed_hint=None):
    """Build the standard event envelope. payload_hash mirrors bronze."""
    env = {
        "source_system": SOURCE_SYSTEM,
        "source_file_name": source_file_name,
        "source_extract_ts": source_extract_ts,
        "file_generation_ts": file_generation_ts,
        "event_type": event_type,
        "business_event_ts": business_event_ts,
        "natural_key": natural_key,
        "payload_hash": payload_hash(payload),
        "payload": payload,
    }
    # Optional, non-authoritative breadcrumb. The bronze layer must NOT trust
    # this — it must independently detect the defect. It exists purely so the
    # generator summary can be reconciled against downstream quarantine counts.
    if malformed_hint is not None:
        env["_synthetic_defect_hint"] = malformed_hint
    return env


# ---------------------------------------------------------------------------
# The generator
# ---------------------------------------------------------------------------
class SyntheticClaimsGenerator:

    def __init__(self, rng, ids, faker, start_date, end_date, as_of,
                 late_rate, adjust_rate, malformed_rate):
        self.rng = rng
        self.ids = ids
        self.faker = faker
        self.start_date = start_date
        self.end_date = end_date
        self.as_of = as_of
        self.late_rate = late_rate
        self.adjust_rate = adjust_rate
        self.malformed_rate = malformed_rate

        # Pre-build stable pools.
        self.npi_pool = ids.provider_pool(max(20, 2))
        self.payer_id = ids.payer_id()
        self.plan_ids = [ids.plan_id() for _ in range(4)]

        # Counters reconciled against the printed summary.
        self.counts = {
            "total": 0, "late": 0, "retro": 0, "adjustments": 0,
            "voids": 0, "reversals": 0, "duplicates": 0, "malformed": 0,
        }

    # -- low level random pickers -------------------------------------------
    def rand_date(self, lo=None, hi=None) -> date:
        lo = lo or self.start_date
        hi = hi or self.end_date
        span = (hi - lo).days
        return lo + timedelta(days=self.rng.randint(0, max(span, 0)))

    def fake_name(self, org=False) -> str:
        if self.faker is not None:
            return self.faker.company() if org else self.faker.name()
        first = ["Avery", "Jordan", "Riley", "Casey", "Quinn", "Reese"]
        last = ["Synthwood", "Mockton", "Testfield", "Fauxberg", "Sampleby"]
        if org:
            return f"{self.rng.choice(last)} {self.rng.choice(['Clinic','Health','Medical Group','Care'])}"
        return f"{self.rng.choice(first)} {self.rng.choice(last)}"

    def fake_address(self) -> dict:
        if self.faker is not None:
            return {
                "line1": self.faker.street_address(),
                "city": self.faker.city(),
                "state": self.rng.choice(US_STATES),
                "zip3": f"{self.rng.randint(0, 999):03d}",
            }
        return {
            "line1": f"{self.rng.randint(1, 9999)} Synthetic Ave",
            "city": "Faketown",
            "state": self.rng.choice(US_STATES),
            "zip3": f"{self.rng.randint(0, 999):03d}",
        }

    # -- CLAIM ---------------------------------------------------------------
    def _build_lines(self, service_from, service_to, n_lines):
        """Build claim lines with self-consistent dollar amounts."""
        lines = []
        for i in range(n_lines):
            charge = round2(self.rng.uniform(40, 2500))
            allowed = round2(charge * self.rng.uniform(0.45, 0.9))
            paid = round2(allowed * self.rng.uniform(0.7, 1.0))
            svc = service_from + timedelta(
                days=self.rng.randint(0, max((service_to - service_from).days, 0)))
            lines.append({
                "claim_line_id": det_uuid(self.rng),
                "line_number": i + 1,
                "procedure_code": self.rng.choice(PROCEDURE_CODES),
                "revenue_code": self.rng.choice(REVENUE_CODES),
                "place_of_service": self.rng.choice(PLACES_OF_SERVICE),
                "service_date": d2s(svc),
                "units": self.rng.randint(1, 4),
                "charge_amount": charge,
                "allowed_amount": allowed,
                "paid_amount": paid,
            })
        return lines

    def _diagnoses(self, claim_type):
        n = self.rng.randint(1, 4)
        out = []
        for pos in range(1, n + 1):
            out.append({
                "diagnosis_code": self.rng.choice(DIAGNOSIS_CODES),
                "diagnosis_position": pos,
                "diagnosis_type": "PRINCIPAL" if pos == 1 else "SECONDARY",
                # POA is only meaningful for institutional claims.
                "present_on_admission": (
                    self.rng.choice(["Y", "N", "U", "W"])
                    if claim_type == "INSTITUTIONAL" else None),
            })
        return out

    def _procedures(self, service_from, service_to):
        n = self.rng.randint(1, 3)
        out = []
        for pos in range(1, n + 1):
            pdate = service_from + timedelta(
                days=self.rng.randint(0, max((service_to - service_from).days, 0)))
            out.append({
                "procedure_code": self.rng.choice(PROCEDURE_CODES),
                "procedure_position": pos,
                "procedure_date": d2s(pdate),
            })
        return out

    def build_clean_claim(self, claim_id=None, claim_version=1, member_id=None,
                          original_claim_id=None, adjustment_type=None,
                          reversal=False, void=False, force_status=None):
        """Build a clean, self-reconciling CLAIM payload."""
        claim_id = claim_id or self.ids.claim_id()
        member_id = member_id or self.ids.member_id()
        claim_type = self.rng.choice(CLAIM_TYPES)

        service_from = self.rand_date()
        service_to = service_from + timedelta(days=self.rng.randint(0, 5))
        # received normally a few days after service.
        received = service_to + timedelta(days=self.rng.randint(1, 10))
        paid = received + timedelta(days=self.rng.randint(1, 21))

        lines = self._build_lines(service_from, service_to,
                                  self.rng.randint(1, 4))
        # Header totals reconcile to the sum of lines (clean invariant).
        total_charge = round2(sum(l["charge_amount"] for l in lines))
        allowed = round2(sum(l["allowed_amount"] for l in lines))
        line_paid = round2(sum(l["paid_amount"] for l in lines))

        status = force_status or self.rng.choices(
            CLAIM_STATUSES, weights=[70, 12, 8, 5, 5])[0]

        denial_reason = None
        paid_amount = line_paid
        if status == "DENIED":
            denial_reason = self.rng.choice(DENIAL_REASON_CODES)
            paid_amount = 0.0
            allowed = 0.0
        elif status == "PENDED":
            paid_amount = 0.0

        # Negative paid amounts are ONLY legal for reversal/void/adjustment.
        if reversal:
            paid_amount = round2(-abs(line_paid))
        elif void:
            paid_amount = 0.0

        patient_resp = round2(max(allowed - paid_amount, 0.0)
                              if status not in ("DENIED",) else 0.0)

        npi_billing = self.rng.choice(self.npi_pool)
        npi_rendering = self.rng.choice(self.npi_pool)
        npi_facility = (self.rng.choice(self.npi_pool)
                        if claim_type == "INSTITUTIONAL" else None)

        payload = {
            "claim_id": claim_id,
            "claim_version": claim_version,
            "member_id": member_id,
            "payer_id": self.payer_id,
            "plan_id": self.rng.choice(self.plan_ids),
            "claim_type": claim_type,
            "claim_status": status,
            "service_from_date": d2s(service_from),
            "service_to_date": d2s(service_to),
            "received_date": d2s(received),
            "paid_date": d2s(paid) if status == "PAID" else None,
            "billing_provider_npi": npi_billing,
            "rendering_provider_npi": npi_rendering,
            "facility_npi": npi_facility,
            "total_charge_amount": total_charge,
            "allowed_amount": allowed,
            "paid_amount": paid_amount,
            "patient_responsibility": patient_resp,
            "denial_reason_code": denial_reason,
            "diagnoses": self._diagnoses(claim_type),
            "procedures": self._procedures(service_from, service_to),
            "lines": lines,
            # Adjustment lineage fields (null on a fresh original).
            "original_claim_id": original_claim_id,
            "adjustment_type": adjustment_type,
            "void_indicator": bool(void),
            "reversal_indicator": bool(reversal),
            "adjustment_reason": (self.rng.choice(ADJUSTMENT_REASONS)
                                  if (adjustment_type or void or reversal)
                                  else None),
        }
        # Track the dates needed for envelope timing decisions.
        meta = {"service_from": service_from, "service_to": service_to,
                "received": received}
        return payload, meta

    def claim_envelope(self, payload, meta, late=False, malformed_hint=None):
        """Wrap a CLAIM payload in an envelope, optionally as a late arrival."""
        received = meta["received"]
        source_file = f"claims_{received:%Y%m%d}.ndjson"
        # business_event_ts ~ when the claim event happened (service/received).
        business_event_ts = iso_dt(meta["received"], self.rng)

        if late:
            # Late arrival: the file is extracted/generated long AFTER the
            # business event (received_date much later than service date).
            extract_d = self.end_date + timedelta(
                days=self.rng.randint(30, 180))
            source_extract_ts = iso_dt(extract_d, self.rng)
            # Also push received far past service to model the late arrival.
            late_received = meta["service_to"] + timedelta(
                days=self.rng.randint(120, 400))
            payload["received_date"] = d2s(late_received)
            payload["payload_late_arrival"] = True
        else:
            source_extract_ts = iso_dt(received + timedelta(days=1), self.rng)

        return make_envelope(
            event_type="CLAIM",
            source_file_name=source_file,
            source_extract_ts=source_extract_ts,
            file_generation_ts=self.as_of,
            business_event_ts=business_event_ts,
            natural_key={"claim_id": payload["claim_id"],
                         "claim_version": payload["claim_version"]},
            payload=payload,
            malformed_hint=malformed_hint,
        )

    # -- ELIGIBILITY ---------------------------------------------------------
    def build_eligibility(self, member_id, retro=False,
                          overlap_claim_service=None):
        cov_start = self.rand_date()
        cov_end = cov_start + timedelta(days=self.rng.randint(90, 730))
        retro_eff = None
        if retro and overlap_claim_service is not None:
            # Backdate coverage to before a prior claim's service date so the
            # retro eligibility now covers a claim that was previously denied
            # for "no coverage".
            retro_eff = overlap_claim_service - timedelta(
                days=self.rng.randint(5, 60))
            cov_start = retro_eff
        payload = {
            "member_id": member_id,
            "payer_id": self.payer_id,
            "plan_id": self.rng.choice(self.plan_ids),
            "plan_type": self.rng.choice(PLAN_TYPES),
            "coverage_start_date": d2s(cov_start),
            "coverage_end_date": d2s(cov_end),
            "eligibility_status": self.rng.choice(["ACTIVE", "TERMED",
                                                   "PENDING"]),
            "retro_active_indicator": bool(retro),
            "retro_effective_date": d2s(retro_eff) if retro_eff else None,
            "demographics": {
                "birth_year": self.rng.randint(1940, 2015),
                "gender": self.rng.choice(GENDERS),
                "state": self.rng.choice(US_STATES),
                "zip3": f"{self.rng.randint(0, 999):03d}",
            },
        }
        biz_d = retro_eff if retro_eff else cov_start
        env = make_envelope(
            event_type="ELIGIBILITY",
            source_file_name=f"eligibility_{cov_start:%Y%m}.ndjson",
            source_extract_ts=iso_dt(cov_start + timedelta(days=1), self.rng),
            file_generation_ts=self.as_of,
            business_event_ts=iso_dt(biz_d, self.rng),
            natural_key={"member_id": member_id,
                         "coverage_start_date": d2s(cov_start)},
            payload=payload,
        )
        return env

    # -- PROVIDER ------------------------------------------------------------
    def build_provider(self, npi):
        ptype = self.rng.choice(PROVIDER_TYPES)
        is_org = ptype == "ORGANIZATION"
        payload = {
            "npi": npi,
            "npi_is_synthetic": True,  # explicit: NOT a real NPPES number
            "provider_name": self.fake_name(org=is_org),
            "specialty": self.rng.choice(SPECIALTIES),
            "taxonomy_code": self.rng.choice(TAXONOMY_CODES),
            "provider_type": ptype,
            "addresses": [self.fake_address()
                          for _ in range(self.rng.randint(1, 2))],
            "billing_vs_rendering_roles": self.rng.sample(
                ["BILLING", "RENDERING", "REFERRING", "FACILITY"],
                k=self.rng.randint(1, 3)),
        }
        return make_envelope(
            event_type="PROVIDER",
            source_file_name="providers_dim.ndjson",
            source_extract_ts=iso_dt(self.start_date, self.rng),
            file_generation_ts=self.as_of,
            business_event_ts=iso_dt(self.start_date, self.rng),
            natural_key={"npi": npi},
            payload=payload,
        )

    # -- PHARMACY ------------------------------------------------------------
    def build_pharmacy(self, member_id):
        fill = self.rand_date()
        charge = round2(self.rng.uniform(8, 900))
        allowed = round2(charge * self.rng.uniform(0.4, 0.95))
        paid = round2(allowed * self.rng.uniform(0.6, 1.0))
        patient_pay = round2(max(allowed - paid, 0.0))
        payload = {
            "pharmacy_claim_id": self.ids.pharmacy_claim_id(),
            "member_id": member_id,
            "ndc": self.ids.ndc(),
            "drug_name": self.rng.choice(DRUG_NAMES),
            "days_supply": self.rng.choice([30, 60, 90, 7, 14]),
            "quantity_dispensed": round2(self.rng.uniform(1, 120)),
            "fill_date": d2s(fill),
            "prescriber_npi": self.rng.choice(self.npi_pool),
            "pharmacy_npi": self.rng.choice(self.npi_pool),
            "charge_amount": charge,
            "allowed_amount": allowed,
            "paid_amount": paid,
            "patient_pay_amount": patient_pay,
        }
        return make_envelope(
            event_type="PHARMACY",
            source_file_name=f"pharmacy_{fill:%Y%m%d}.ndjson",
            source_extract_ts=iso_dt(fill + timedelta(days=1), self.rng),
            file_generation_ts=self.as_of,
            business_event_ts=iso_dt(fill, self.rng),
            natural_key={"pharmacy_claim_id": payload["pharmacy_claim_id"]},
            payload=payload,
        )

    # -- ADJUDICATION (835-style) -------------------------------------------
    def build_adjudication(self, claim_id, event_type, prior_version,
                           new_version, paid_delta, when,
                           adjustment_type=None, denial_reason=None):
        payload = {
            "claim_id": claim_id,
            "adjudication_event_id": det_uuid(self.rng),
            "event_type": event_type,
            "event_ts": iso_dt(when, self.rng),
            "adjustment_type": adjustment_type,
            "adjustment_reason": (self.rng.choice(ADJUSTMENT_REASONS)
                                  if adjustment_type else None),
            "prior_claim_version": prior_version,
            "new_claim_version": new_version,
            "denial_reason_code": denial_reason,
            "paid_amount_delta": round2(paid_delta),
        }
        return make_envelope(
            event_type="ADJUDICATION",
            source_file_name=f"adjudication_{when:%Y%m%d}.ndjson",
            source_extract_ts=iso_dt(when + timedelta(days=1), self.rng),
            file_generation_ts=self.as_of,
            business_event_ts=iso_dt(when, self.rng),
            natural_key={"claim_id": claim_id,
                         "adjudication_event_id": payload[
                             "adjudication_event_id"]},
            payload=payload,
        )

    # -- MALFORMED injectors -------------------------------------------------
    # Each returns a structurally-parseable JSON object that is SEMANTICALLY
    # broken so the bronze quarantine logic has something to catch. We tag a
    # non-authoritative hint for our own reconciliation only.
    def build_malformed_claim(self):
        payload, meta = self.build_clean_claim()
        defect = self.rng.choice([
            "MISSING_MEMBER_ID", "MISSING_CLAIM_ID", "SERVICE_TO_BEFORE_FROM",
            "FUTURE_SERVICE_DATE", "NEGATIVE_PAID_NON_ADJUSTMENT",
            "HEADER_LINE_MISMATCH",
        ])
        if defect == "MISSING_MEMBER_ID":
            payload["member_id"] = None
        elif defect == "MISSING_CLAIM_ID":
            payload["claim_id"] = None
            meta = dict(meta)  # natural_key will carry a null claim_id
        elif defect == "SERVICE_TO_BEFORE_FROM":
            # impossible date range
            payload["service_to_date"] = d2s(
                meta["service_from"] - timedelta(days=3))
        elif defect == "FUTURE_SERVICE_DATE":
            future = self.end_date + timedelta(days=self.rng.randint(400, 900))
            payload["service_from_date"] = d2s(future)
            payload["service_to_date"] = d2s(future + timedelta(days=1))
        elif defect == "NEGATIVE_PAID_NON_ADJUSTMENT":
            # negative paid while NOT a reversal/void/adjustment -> illegal
            payload["paid_amount"] = round2(-abs(payload["paid_amount"]) - 10)
            payload["reversal_indicator"] = False
            payload["void_indicator"] = False
            payload["adjustment_type"] = None
        elif defect == "HEADER_LINE_MISMATCH":
            # break the header-vs-line reconciliation invariant
            payload["total_charge_amount"] = round2(
                payload["total_charge_amount"] + self.rng.uniform(500, 5000))
            payload["paid_amount"] = round2(
                payload["paid_amount"] + self.rng.uniform(100, 900))
        env = self.claim_envelope(payload, meta, late=False,
                                  malformed_hint=defect)
        # If claim_id was nulled, reflect it in the natural_key too.
        if defect == "MISSING_CLAIM_ID":
            env["natural_key"]["claim_id"] = None
        return env


# ---------------------------------------------------------------------------
# Orchestration: build the full dataset and write NDJSON files.
# ---------------------------------------------------------------------------
def write_ndjson(path: Path, records: list) -> None:
    with path.open("w", encoding="utf-8") as f:
        for rec in records:
            f.write(json.dumps(rec, default=str))
            f.write("\n")


def generate(args):
    rng = __import__("random").Random(args.seed)
    ids = IdFactory(rng)
    faker = None
    if _HAVE_FAKER:
        faker = Faker()
        Faker.seed(args.seed)  # keep Faker deterministic too

    start_date = datetime.strptime(args.start_date, "%Y-%m-%d").date()
    end_date = datetime.strptime(args.end_date, "%Y-%m-%d").date()

    gen = SyntheticClaimsGenerator(
        rng=rng, ids=ids, faker=faker, start_date=start_date,
        end_date=end_date, as_of=args.as_of, late_rate=args.late_rate,
        adjust_rate=args.adjust_rate, malformed_rate=args.malformed_rate)

    claim_events = []
    eligibility_events = []
    provider_events = []
    pharmacy_events = []
    adjudication_events = []
    malformed_events = []  # mirrored copy of malformed rows for convenience

    # 1) Providers (dimension) from the stable NPI pool.
    for npi in gen.npi_pool:
        provider_events.append(gen.build_provider(npi))

    # Track per-member the service date of a denied claim, so retro
    # eligibility can be backdated to cover it.
    member_ids = [ids.member_id() for _ in range(args.members)]

    # Roughly 1.6 claims per member on average.
    n_claims = int(args.members * 1.6)

    for _ in range(n_claims):
        member_id = rng.choice(member_ids)

        # --- malformed branch -------------------------------------------
        if rng.random() < gen.malformed_rate:
            env = gen.build_malformed_claim()
            claim_events.append(env)
            malformed_events.append(env)
            gen.counts["total"] += 1
            gen.counts["malformed"] += 1
            continue

        # --- normal / late claim ----------------------------------------
        late = rng.random() < gen.late_rate
        payload, meta = gen.build_clean_claim(member_id=member_id)
        env = gen.claim_envelope(payload, meta, late=late)
        claim_events.append(env)
        gen.counts["total"] += 1
        if late:
            gen.counts["late"] += 1

        # --- duplicate injection (same natural key) ---------------------
        if rng.random() < 0.03:
            dup = json.loads(json.dumps(env, default=str))  # deep copy
            # Same natural key. Sometimes identical payload_hash (true dupe),
            # sometimes a trivially different payload (logical dupe).
            if rng.random() < 0.5:
                dup["payload"]["paid_amount"] = round2(
                    dup["payload"]["paid_amount"] + 0.01)
                dup["payload_hash"] = payload_hash(dup["payload"])
            dup["source_file_name"] = "claims_redelivery.ndjson"
            claim_events.append(dup)
            gen.counts["total"] += 1
            gen.counts["duplicates"] += 1

        # --- adjustment / void / reversal chain -------------------------
        if rng.random() < gen.adjust_rate and payload["claim_id"]:
            kind = rng.choices(["ADJUST", "VOID", "REVERSAL"],
                               weights=[60, 20, 20])[0]
            new_version = payload["claim_version"] + 1
            adj_when = meta["received"] + timedelta(days=rng.randint(15, 120))

            if kind == "ADJUST":
                adj_payload, adj_meta = gen.build_clean_claim(
                    claim_id=payload["claim_id"], claim_version=new_version,
                    member_id=member_id,
                    original_claim_id=payload["claim_id"],
                    adjustment_type="REPLACEMENT")
                adj_payload["service_from_date"] = payload["service_from_date"]
                adj_payload["service_to_date"] = payload["service_to_date"]
                adj_env = gen.claim_envelope(adj_payload, meta, late=False)
                claim_events.append(adj_env)
                gen.counts["total"] += 1
                gen.counts["adjustments"] += 1
                delta = round2(adj_payload["paid_amount"]
                               - payload["paid_amount"])
                adjudication_events.append(gen.build_adjudication(
                    payload["claim_id"], "ADJUSTED", payload["claim_version"],
                    new_version, delta, adj_when, adjustment_type="REPLACEMENT"))

            elif kind == "VOID":
                void_payload, _ = gen.build_clean_claim(
                    claim_id=payload["claim_id"], claim_version=new_version,
                    member_id=member_id,
                    original_claim_id=payload["claim_id"],
                    adjustment_type="VOID", void=True, force_status="VOID")
                void_env = gen.claim_envelope(void_payload, meta, late=False)
                claim_events.append(void_env)
                gen.counts["total"] += 1
                gen.counts["voids"] += 1
                adjudication_events.append(gen.build_adjudication(
                    payload["claim_id"], "VOID", payload["claim_version"],
                    new_version, round2(-payload["paid_amount"]), adj_when,
                    adjustment_type="VOID"))

            else:  # REVERSAL (negative paid allowed)
                rev_payload, _ = gen.build_clean_claim(
                    claim_id=payload["claim_id"], claim_version=new_version,
                    member_id=member_id,
                    original_claim_id=payload["claim_id"],
                    adjustment_type="REVERSAL", reversal=True,
                    force_status="REVERSED")
                rev_env = gen.claim_envelope(rev_payload, meta, late=False)
                claim_events.append(rev_env)
                gen.counts["total"] += 1
                gen.counts["reversals"] += 1
                adjudication_events.append(gen.build_adjudication(
                    payload["claim_id"], "REVERSED", payload["claim_version"],
                    new_version, rev_payload["paid_amount"], adj_when,
                    adjustment_type="REVERSAL"))

        # --- a plain adjudication record for the original ----------------
        adjudication_events.append(gen.build_adjudication(
            payload["claim_id"] or "UNKNOWN",
            "DENIED" if payload["claim_status"] == "DENIED" else "ADJUDICATED",
            None, payload["claim_version"], payload["paid_amount"],
            meta["received"],
            denial_reason=payload["denial_reason_code"]))

    # 2) Eligibility: one baseline per member + retroactive examples.
    retro_target = max(1, int(args.members * 0.05))
    for member_id in member_ids:
        eligibility_events.append(gen.build_eligibility(member_id))
    # Retroactive eligibility overlapping a prior (denied) claim's service.
    denied_claims = [e for e in claim_events
                     if e["payload"].get("claim_status") == "DENIED"
                     and e["payload"].get("member_id")]
    rng.shuffle(denied_claims)
    for e in denied_claims[:retro_target]:
        svc = datetime.strptime(
            e["payload"]["service_from_date"], "%Y-%m-%d").date()
        eligibility_events.append(gen.build_eligibility(
            e["payload"]["member_id"], retro=True, overlap_claim_service=svc))
        gen.counts["retro"] += 1

    # 3) Pharmacy: ~0.5 per member.
    for _ in range(int(args.members * 0.5)):
        pharmacy_events.append(gen.build_pharmacy(rng.choice(member_ids)))

    # 4) A few malformed eligibility/pharmacy rows for cross-file quarantine.
    for _ in range(max(1, int(args.members * gen.malformed_rate * 0.2))):
        bad = gen.build_eligibility(rng.choice(member_ids))
        bad["payload"]["member_id"] = None  # missing business key
        bad["natural_key"]["member_id"] = None
        # Recompute the hash so the envelope stays an honest mirror of payload.
        bad["payload_hash"] = payload_hash(bad["payload"])
        bad["_synthetic_defect_hint"] = "MISSING_MEMBER_ID"
        eligibility_events.append(bad)
        malformed_events.append(bad)
        gen.counts["malformed"] += 1

    # ---- write files ------------------------------------------------------
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    files = {
        "claim_events.ndjson": claim_events,
        "eligibility_events.ndjson": eligibility_events,
        "provider_events.ndjson": provider_events,
        "pharmacy_events.ndjson": pharmacy_events,
        "adjudication_events.ndjson": adjudication_events,
        "claim_events_malformed.ndjson": malformed_events,
    }
    for name, recs in files.items():
        write_ndjson(out / name, recs)

    # ---- summary ----------------------------------------------------------
    print("=" * 70)
    print(" SYNTHETIC HEALTHCARE CLAIMS GENERATOR  —  100% FABRICATED DATA")
    print(" NOT real Medicare/Medicaid/CMS/PHI. For testing/demo use only.")
    print("=" * 70)
    print(f" seed={args.seed}  members={args.members}  "
          f"window={args.start_date}..{args.end_date}  as_of={args.as_of}")
    print(f" rates: late={args.late_rate} adjust={args.adjust_rate} "
          f"malformed={args.malformed_rate}  "
          f"faker={'on' if _HAVE_FAKER else 'off (stdlib)'}")
    print("-" * 70)
    print(" File record counts:")
    for name, recs in files.items():
        print(f"   {name:<34} {len(recs):>8,}")
    print("-" * 70)
    print(" Injected-event tallies (claims stream):")
    for k in ["total", "late", "retro", "adjustments", "voids",
              "reversals", "duplicates", "malformed"]:
        print(f"   {k:<14} {gen.counts[k]:>8,}")
    print("=" * 70)
    print(f" Output written to: {out.resolve()}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def build_arg_parser():
    p = argparse.ArgumentParser(
        description="Generate 100%% SYNTHETIC healthcare claims NDJSON "
                    "(NOT real Medicare/Medicaid/CMS/PHI).")
    p.add_argument("--members", type=int, default=500,
                   help="Number of synthetic members (default 500).")
    p.add_argument("--start-date", default="2024-01-01",
                   help="Service window start YYYY-MM-DD (default 2024-01-01).")
    p.add_argument("--end-date", default="2025-12-31",
                   help="Service window end YYYY-MM-DD (default 2025-12-31).")
    p.add_argument("--seed", type=int, default=42,
                   help="RNG seed for deterministic output (default 42).")
    p.add_argument("--out", default="output/",
                   help="Output directory for NDJSON files (default output/).")
    p.add_argument("--as-of", default=DEFAULT_AS_OF,
                   help="file_generation_ts (ISO-8601). Fixed, NOT wall-clock, "
                        "so runs are reproducible. Default %s." % DEFAULT_AS_OF)
    p.add_argument("--late-rate", type=float, default=0.08,
                   help="Fraction of claims that arrive late (default 0.08).")
    p.add_argument("--adjust-rate", type=float, default=0.12,
                   help="Fraction of claims with adjust/void/reversal chains "
                        "(default 0.12).")
    p.add_argument("--malformed-rate", type=float, default=0.05,
                   help="Fraction of malformed claims for quarantine testing "
                        "(default 0.05).")
    return p


def main():
    args = build_arg_parser().parse_args()
    generate(args)


if __name__ == "__main__":
    main()
