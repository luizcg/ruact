# Security Policy

## Supported Versions

Only the latest patch release of the current minor version is actively maintained for security fixes.

| Version | Supported |
|---------|-----------|
| 0.1.x   | ✅ Yes    |

Once a new minor version is released, the previous minor version receives security fixes for **90 days** after the new release, then it is no longer supported.

---

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Please use [GitHub Security Advisories](https://github.com/luizcg/ruact/security/advisories/new) to report vulnerabilities privately. This keeps the report confidential until a fix is prepared and released.

### What to include

- A description of the vulnerability and its potential impact
- Steps to reproduce (a minimal proof-of-concept if possible)
- The version(s) of `ruact` you tested against
- Any suggested mitigations or patches, if you have them

### Response timeline

| Milestone | Target |
|-----------|--------|
| Initial acknowledgement | **Within 14 days** of receiving the report |
| Triage and severity assessment | Within 30 days |
| Patch release for confirmed vulnerabilities | Within 90 days |

If a reported vulnerability is accepted, you will be credited in the CHANGELOG and GitHub Security Advisory unless you prefer to remain anonymous.

If a report is declined (e.g. the reported behaviour is by design or the impact is below our threshold), we will explain our reasoning.

---

## Disclosure Policy

We follow [Coordinated Vulnerability Disclosure](https://vuls.cert.org/confluence/display/CVD): we ask that you give us a reasonable amount of time to fix the issue before publishing details publicly. We aim to meet the timelines above so that you are not kept waiting.

---

## Out of Scope

The following are generally not considered security vulnerabilities for this gem:

- Vulnerabilities in Rails, React, Nokogiri, or other dependencies — report those to the respective projects
- Theoretical attacks with no practical exploitability
- Denial-of-service via extremely large inputs (unless the gem has no guard and the impact is severe)

---

## Contact

Primary channel: [GitHub Security Advisories](https://github.com/luizcg/ruact/security/advisories/new) (preferred — keeps reports private)

Maintainer: Luiz Garcia — see GitHub profile for additional contact options.
