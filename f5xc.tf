# -----------------------------------------------------------------------------
# F5 XC Secure Mesh Site v2 + Token + Cloud-Init
# -----------------------------------------------------------------------------

resource "volterra_securemesh_site_v2" "this" {
  name      = local.prefix
  namespace = "system"

  description             = var.site_description
  block_all_services      = false
  logs_streaming_disabled = true

  labels = merge(
    { "ves.io/provider" = "ves-io-AZURE" },
    var.enable_site_mesh_group ? { (var.site_mesh_label_key) = var.site_mesh_label_value } : {}
  )

  offline_survivability_mode {
    enable_offline_survivability_mode = true
  }

  admin_user_credentials {
    ssh_key = var.ssh_public_key
  }

  re_select {
    geo_proximity = true
  }

  # Site-to-site connectivity via site mesh groups over SLO public IP
  dynamic "site_mesh_group_on_slo" {
    for_each = var.enable_site_mesh_group ? [1] : []
    content {
      sm_connection_public_ip = true
    }
  }

  no_s2s_connectivity_slo = var.enable_site_mesh_group ? false : true

  azure {
    not_managed {}
  }

  # The CE adds hardware/OS metadata labels during registration.
  # Ignore them so Terraform doesn't try to remove them on every apply.
  lifecycle {
    ignore_changes = [labels]
  }
}

resource "volterra_token" "this" {
  depends_on = [volterra_securemesh_site_v2.this]
  name       = "${local.prefix}-token"
  namespace  = "system"
  type       = 1
  site_name  = volterra_securemesh_site_v2.this.name
}

locals {
  # For SMSv2 JWT tokens (type=1), the token ID IS the JWT string.
  # The JWT carries cluster_name, tenant, and registration endpoints.
  site_token = replace(volterra_token.this.id, "id=", "")

  ce_user_data = <<-YAML
    #cloud-config
    write_files:
      - path: /etc/vpm/user_data
        permissions: '0644'
        owner: root
        content: |
          token: ${local.site_token}
    %{if var.enable_etcd_fix}

      # TEMPORARY: Workaround for VPM bug that leaves ETCD_IMAGE blank
      # in /etc/default/etcd-member. Remove when CE image is patched.
      # Toggle off with: enable_etcd_fix = false
      - path: /usr/local/bin/fix-etcd-image.sh
        permissions: '0755'
        owner: root
        content: |
          #!/bin/bash
          # TEMPORARY fix — remove when VPM image is patched.
          # VPM writes certs, peers, and cipher suites to /etc/default/etcd-member
          # but fails to populate ETCD_IMAGE from vpm_etcd_image during registration.

          ETCD_MEMBER="/etc/default/etcd-member"
          ETCD_IMAGE="${var.ce_etcd_image}"
          LOG_TAG="fix-etcd-image"
          MAX_WAIT=1800

          log() { logger -t "$LOG_TAG" "$1"; echo "$LOG_TAG: $1"; }

          # --- Wait for VPM to write etcd-member ---
          elapsed=0
          while [ ! -f "$ETCD_MEMBER" ]; do
            if [ "$elapsed" -ge "$MAX_WAIT" ]; then
              log "ERROR: $ETCD_MEMBER not found after $${MAX_WAIT}s. Giving up."
              exit 1
            fi
            sleep 10
            elapsed=$((elapsed + 10))
          done
          log "Found $ETCD_MEMBER after $${elapsed}s"

          # --- Check if ETCD_IMAGE is already populated ---
          if ! grep -q '^ETCD_IMAGE=$' "$ETCD_MEMBER"; then
            CURRENT=$(grep '^ETCD_IMAGE=' "$ETCD_MEMBER" | head -1)
            log "ETCD_IMAGE already set: $CURRENT — nothing to fix."
            exit 0
          fi

          log "ETCD_IMAGE is blank. Patching with: $ETCD_IMAGE"
          sed -i "s|^ETCD_IMAGE=$|ETCD_IMAGE=$ETCD_IMAGE|" "$ETCD_MEMBER"

          # Verify the patch took effect
          if grep -q "^ETCD_IMAGE=$ETCD_IMAGE" "$ETCD_MEMBER"; then
            log "Successfully patched $ETCD_MEMBER"
          else
            log "ERROR: Patch verification failed."
            exit 1
          fi

          # --- Restart etcd ---
          log "Restarting etcd-member.service..."
          systemctl restart etcd-member.service
          sleep 5
          if systemctl is-active --quiet etcd-member.service; then
            log "etcd-member.service is now running."
          else
            log "WARNING: etcd-member.service not yet running (may need more time to initialize)."
          fi

      - path: /etc/systemd/system/fix-etcd-image.service
        permissions: '0644'
        owner: root
        content: |
          [Unit]
          Description=TEMPORARY: fix blank ETCD_IMAGE in /etc/default/etcd-member
          After=vpm.service crio.service
          Wants=vpm.service

          [Service]
          Type=oneshot
          ExecStart=/usr/local/bin/fix-etcd-image.sh
          TimeoutStartSec=900
          RemainAfterExit=false
          StandardOutput=journal
          StandardError=journal

          [Install]
          WantedBy=multi-user.target

    runcmd:
      - systemctl daemon-reload
      - systemctl enable fix-etcd-image.service
      - systemctl start fix-etcd-image.service --no-block
    %{endif}
  YAML
}
