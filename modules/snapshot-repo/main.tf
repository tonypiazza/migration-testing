locals {
  job_name = var.job_name != "" ? var.job_name : "snapshot-repo-${var.name}"

  # Repository registration body: {"type": <backend>, "settings": {...}}
  repo_body = jsonencode({
    type     = var.repo_type
    settings = var.repo_settings
  })

  # Registration script. Runs inside the cluster, so it reaches the search API over
  # service DNS whether the external endpoint is public or PSC-internal. Retries until
  # the API answers, then PUTs the repo and fails (non-zero exit) on any non-2xx so the
  # Terraform Job reports failure instead of silently "completing".
  register_script = <<-EOT
    set -eu
    url="${var.endpoint}/_snapshot/${var.name}"
    for i in $(seq 1 30); do
      if curl -sk -u "$USERNAME:$PASSWORD" -o /dev/null "${var.endpoint}/_cluster/health"; then
        break
      fi
      echo "waiting for search API ($i/30)..."; sleep 10
    done
    echo "registering snapshot repository '${var.name}' at $url"
    curl -sk --fail-with-body -u "$USERNAME:$PASSWORD" \
      -H 'Content-Type: application/json' \
      -X PUT "$url" \
      -d '${local.repo_body}'
  EOT
}

resource "kubernetes_job_v1" "register" {
  metadata {
    name      = local.job_name
    namespace = var.namespace
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = {
          "app.kubernetes.io/managed-by" = "terraform"
          "app.kubernetes.io/component"  = "snapshot-repo-register"
        }
      }

      spec {
        restart_policy = "Never"

        container {
          name    = "register"
          image   = var.curl_image
          command = ["sh", "-c", local.register_script]

          env {
            name  = "USERNAME"
            value = var.username
          }

          env {
            name = "PASSWORD"
            value_from {
              secret_key_ref {
                name = var.credentials_secret
                key  = var.password_key
              }
            }
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
  }
}
