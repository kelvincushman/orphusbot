//! Secrets (DESIGN §11, PRD B-INT-04): values the owner gives bots, such as an
//! MCP server's token. Encrypted at rest with AES-256-GCM under a master key
//! kept outside the database, and redacted from everything shown or stored.

use std::sync::RwLock;

use anyhow::Context;
use openssl::symm::{Cipher, decrypt_aead, encrypt_aead};
use orphusbot_proto::ThreadEvent;
use sqlx::PgPool;

/// Shorter values would redact ordinary words.
pub const MIN_LEN: usize = 8;

pub struct Secrets {
    // ponytail: one master key encrypts every value directly; per-value data
    // keys (envelope encryption) when the master key must rotate without re-encrypting.
    key: Option<[u8; 32]>,
    /// Every stored value in each form it might appear in, for redaction.
    known: RwLock<Vec<String>>,
}

impl Secrets {
    /// `ORPHUSBOT_SECRET_KEY_FILE`: 32 random bytes, for example a `systemd-creds`
    /// credential. Without it, secrets can't be stored.
    pub fn from_env() -> anyhow::Result<Self> {
        let key = match std::env::var("ORPHUSBOT_SECRET_KEY_FILE") {
            Ok(path) => {
                let bytes = std::fs::read(&path).with_context(|| format!("reading {path}"))?;
                let key: [u8; 32] = bytes.try_into().map_err(|b: Vec<u8>| {
                    anyhow::anyhow!("{path} holds {} bytes; it needs exactly 32", b.len())
                })?;
                Some(key)
            }
            Err(_) => None,
        };
        Ok(Self::with_key(key))
    }

    pub fn with_key(key: Option<[u8; 32]>) -> Self {
        Self {
            key,
            known: RwLock::default(),
        }
    }

    pub fn enabled(&self) -> bool {
        self.key.is_some()
    }

    /// Encrypts and stores `value`; `None` when there's no master key.
    pub async fn store(&self, db: &PgPool, value: &str) -> anyhow::Result<Option<i64>> {
        let Some(key) = &self.key else {
            return Ok(None);
        };
        let mut nonce = [0u8; 12];
        getrandom::fill(&mut nonce).map_err(|e| anyhow::anyhow!("no randomness: {e}"))?;
        let mut tag = [0u8; 16];
        let ciphertext = encrypt_aead(
            Cipher::aes_256_gcm(),
            key,
            Some(&nonce),
            &[],
            value.as_bytes(),
            &mut tag,
        )?;
        let id = sqlx::query_scalar!(
            "insert into secret (nonce, ciphertext, tag) values ($1, $2, $3) returning id",
            &nonce[..],
            ciphertext,
            &tag[..]
        )
        .fetch_one(db)
        .await?;
        self.learn(value);
        Ok(Some(id))
    }

    /// The plain value; an error if it can't be decrypted (wrong key, tampering).
    pub async fn reveal(&self, db: &PgPool, id: i64) -> anyhow::Result<String> {
        let key = self.key.as_ref().context("no master key")?;
        let row = sqlx::query!(
            "select nonce, ciphertext, tag from secret where id = $1",
            id
        )
        .fetch_one(db)
        .await?;
        let plain = decrypt_aead(
            Cipher::aes_256_gcm(),
            key,
            Some(&row.nonce),
            &[],
            &row.ciphertext,
            &row.tag,
        )
        .context(
            "a secret didn't decrypt: is ORPHUSBOT_SECRET_KEY_FILE the key it was stored with?",
        )?;
        Ok(String::from_utf8(plain)?)
    }

    /// Learns every stored value for redaction. Called at start and after a delete.
    pub async fn load(&self, db: &PgPool) -> anyhow::Result<()> {
        if let Ok(mut known) = self.known.write() {
            known.clear();
        }
        if self.key.is_none() {
            return Ok(());
        }
        let ids = sqlx::query_scalar!("select id from secret")
            .fetch_all(db)
            .await?;
        for id in ids {
            let value = self.reveal(db, id).await?;
            self.learn(&value);
        }
        Ok(())
    }

    fn learn(&self, value: &str) {
        let forms = [
            value.to_owned(),
            openssl::base64::encode_block(value.as_bytes()),
            url_encoded(value),
        ];
        if let Ok(mut known) = self.known.write() {
            for form in forms {
                if form.len() >= MIN_LEN && !known.contains(&form) {
                    known.push(form);
                }
            }
        }
    }

    pub fn redact(&self, text: &str) -> String {
        let mut text = text.to_owned();
        if let Ok(known) = self.known.read() {
            for value in known.iter() {
                if text.contains(value.as_str()) {
                    text = text.replace(value.as_str(), "[secret]");
                }
            }
        }
        text
    }

    /// The event with every secret replaced by `[secret]`.
    pub fn redact_event(&self, event: ThreadEvent) -> ThreadEvent {
        if self.known.read().map(|k| k.is_empty()).unwrap_or(true) {
            return event;
        }
        let Ok(json) = serde_json::to_string(&event) else {
            return event;
        };
        let clean = self.redact(&json);
        if clean == json {
            return event;
        }
        // A secret that JSON had to escape can't be matched inside it; the text is hidden rather than leaked.
        serde_json::from_str(&clean).unwrap_or(ThreadEvent::Notice {
            text: "Hidden: this contained a secret.".into(),
        })
    }
}

/// Percent-encodes everything but RFC 3986's unreserved characters.
fn url_encoded(value: &str) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[sqlx::test]
    async fn stored_encrypted_and_redacted_in_every_form(db: PgPool) {
        let secrets = Secrets::with_key(Some([7; 32]));
        let id = secrets.store(&db, "tok/en+12345").await.unwrap().unwrap();
        let raw: Vec<u8> = sqlx::query_scalar!("select ciphertext from secret where id = $1", id)
            .fetch_one(&db)
            .await
            .unwrap();
        assert!(!String::from_utf8_lossy(&raw).contains("tok/en"));
        assert_eq!(secrets.reveal(&db, id).await.unwrap(), "tok/en+12345");

        let said = "plain tok/en+12345, base64 dG9rL2VuKzEyMzQ1, url tok%2Fen%2B12345";
        assert_eq!(
            secrets.redact(said),
            "plain [secret], base64 [secret], url [secret]"
        );
        let event = ThreadEvent::Notice { text: said.into() };
        assert_eq!(
            secrets.redact_event(event),
            ThreadEvent::Notice {
                text: "plain [secret], base64 [secret], url [secret]".into()
            }
        );

        // Another key can't read it, and a fresh process learns values at start.
        assert!(
            Secrets::with_key(Some([8; 32]))
                .reveal(&db, id)
                .await
                .is_err()
        );
        let restarted = Secrets::with_key(Some([7; 32]));
        restarted.load(&db).await.unwrap();
        assert_eq!(restarted.redact("x tok/en+12345"), "x [secret]");
        // No key: nothing is stored.
        assert!(
            Secrets::with_key(None)
                .store(&db, "whatever-value")
                .await
                .unwrap()
                .is_none()
        );
    }
}
