//! The node's identity: its name and Ed25519 key, saved by `orphusbot-node
//! enrol` and used to sign the server's challenge on every connection
//! (DESIGN §4.1).

use std::fs;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use anyhow::Context;
use openssl::pkey::{Id, PKey, Private};
use openssl::sign::Signer;
use orphusbot_proto::link_proof;
use serde_json::json;

pub struct NodeKey {
    pub name: String,
    key: PKey<Private>,
}

impl NodeKey {
    pub fn generate(name: String) -> anyhow::Result<Self> {
        Ok(Self {
            name,
            key: PKey::generate_ed25519()?,
        })
    }

    pub fn public_hex(&self) -> anyhow::Result<String> {
        Ok(hex::encode(self.key.raw_public_key()?))
    }

    /// Hex signature of the link proof for this node and `nonce`.
    pub fn sign(&self, nonce: &str) -> anyhow::Result<String> {
        let proof = link_proof(&self.name, nonce);
        let mut signer = Signer::new_without_digest(&self.key)?;
        Ok(hex::encode(signer.sign_oneshot_to_vec(proof.as_bytes())?))
    }

    /// Writes the key file, readable only by this user. Replaces an old one.
    pub fn save(&self, path: &Path) -> anyhow::Result<()> {
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        }
        let body = json!({ "name": self.name, "key": hex::encode(self.key.raw_private_key()?) });
        // Remove first: the mode below only applies to a new file.
        let _ = fs::remove_file(path);
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(path)
            .and_then(|mut f| f.write_all(body.to_string().as_bytes()))
            .with_context(|| format!("writing {}", path.display()))
    }

    pub fn load(path: &Path) -> anyhow::Result<Self> {
        let text = fs::read_to_string(path).with_context(|| {
            format!(
                "no node key at {}; enrol first with `orphusbot-node enrol <code>`",
                path.display()
            )
        })?;
        let v: serde_json::Value = serde_json::from_str(&text).context("reading the node key")?;
        let (Some(name), Some(key)) = (v["name"].as_str(), v["key"].as_str()) else {
            anyhow::bail!(
                "the node key file {} is damaged; enrol again",
                path.display()
            );
        };
        let key = PKey::private_key_from_raw_bytes(&hex::decode(key)?, Id::ED25519)?;
        Ok(Self {
            name: name.to_owned(),
            key,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openssl::sign::Verifier;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn saved_key_loads_private_and_signs_verifiably() {
        let path =
            std::env::temp_dir().join(format!("orphusbot-key-test-{}.json", std::process::id()));
        let key = NodeKey::generate("laptop".into()).unwrap();
        key.save(&path).unwrap();
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let loaded = NodeKey::load(&path).unwrap();
        fs::remove_file(&path).unwrap();

        assert_eq!(loaded.name, "laptop");
        assert_eq!(loaded.public_hex().unwrap(), key.public_hex().unwrap());
        let public = PKey::public_key_from_raw_bytes(
            &hex::decode(key.public_hex().unwrap()).unwrap(),
            Id::ED25519,
        )
        .unwrap();
        let signature = hex::decode(loaded.sign("n1").unwrap()).unwrap();
        let mut verifier = Verifier::new_without_digest(&public).unwrap();
        assert!(
            verifier
                .verify_oneshot(&signature, link_proof("laptop", "n1").as_bytes())
                .unwrap()
        );
    }
}
