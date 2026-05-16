# TLS Certificates

Place your TLS certificates in this directory for HTTPS support:

- **`fullchain.pem`** — Full certificate chain (server cert + intermediates)
- **`privkey.pem`** — Private key (RSA or ECDSA)

## Quick start with Let's Encrypt (certbot)

```bash
# Obtain certificates
sudo certbot certonly --standalone -d your-domain.com

# Copy into this directory
sudo cp /etc/letsencrypt/live/your-domain.com/fullchain.pem docker/certs/
sudo cp /etc/letsencrypt/live/your-domain.com/privkey.pem docker/certs/
sudo chown $(id -u):$(id -g) docker/certs/*.pem
```

## Quick start with self-signed (development only)

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout docker/certs/privkey.pem \
  -out docker/certs/fullchain.pem \
  -subj "/CN=octo.local"
```

## Enabling HTTPS

After placing certificates here:

1. Uncomment the `443` port mapping in `docker/docker-compose.yaml`
2. Uncomment the certs volume mount in `docker/docker-compose.yaml`
3. Uncomment the HTTPS server block in `docker/nginx/conf.d/octo.conf.template`
4. Set `OCTO_TLS_ENABLED=true` in `docker/.env`
5. Restart: `docker compose up -d`

> **Note:** The `.gitignore` excludes `*.pem` files from version control.
> Never commit private keys to the repository.
