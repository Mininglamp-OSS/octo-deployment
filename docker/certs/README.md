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

1. Uncomment the HTTPS server block in
   `docker/nginx/conf.d/octo.conf.template`. HTTP on port 80 and HTTPS
   on port 443 can coexist (HTTP will not auto-redirect to HTTPS); the
   shipped HTTP and HTTPS blocks each declare `listen … default_server`
   on a different port, so they do not collide.

   The conflict you should avoid is enabling a *second* port 80 server
   block (for example, a dedicated `HTTP → HTTPS` redirect block) while
   the original HTTP server block is still active — both would claim
   `listen 80 default_server` and nginx would refuse to start with
   "a duplicate default server". If you want a permanent HTTP→HTTPS
   redirect, either replace the body of the existing HTTP block with a
   `301` to `https://$host$request_uri`, or comment out the original
   HTTP block before adding a separate redirect block.
2. Uncomment the `443` port mapping in `docker/docker-compose.yaml`
3. Uncomment the certs volume mount in `docker/docker-compose.yaml`
4. Restart: `docker compose up -d`

> **Note:** The `.gitignore` excludes `*.pem` files from version control.
> Never commit private keys to the repository.
