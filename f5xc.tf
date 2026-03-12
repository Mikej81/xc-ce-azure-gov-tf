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

# -----------------------------------------------------------------------------
# Day-2 API provisioners — set public IP and segment interface on the SMSv2
# site object after the CE registers. Auth prefers API token; falls back to P12.
# -----------------------------------------------------------------------------

resource "terraform_data" "set_public_ip" {
  count = var.create_public_ip ? 1 : 0

  triggers_replace = [azurerm_public_ip.slo[0].ip_address]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      F5XC_API_TOKEN = var.f5xc_api_token != null ? var.f5xc_api_token : ""
    }
    command = <<-SCRIPT
      set -euo pipefail

      API_URL="${var.f5xc_api_url}"
      P12_FILE="${var.f5xc_api_p12_file}"
      SITE_NAME="${volterra_securemesh_site_v2.this.name}"
      PUBLIC_IP="${azurerm_public_ip.slo[0].ip_address}"
      MAX_WAIT=3600
      POLL_INTERVAL=30

      # --- Auth: prefer API token, fall back to P12 cert ---
      if [ -n "$${F5XC_API_TOKEN:-}" ]; then
        CURL_AUTH=(-H "Authorization: APIToken $F5XC_API_TOKEN")
      else
        CERT_FILE=$(mktemp) KEY_FILE=$(mktemp)
        trap "rm -f $CERT_FILE $KEY_FILE" EXIT
        openssl pkcs12 -in "$P12_FILE" -passin "pass:$${VES_P12_PASSWORD}" -clcerts -nokeys -legacy > "$CERT_FILE" 2>/dev/null
        openssl pkcs12 -in "$P12_FILE" -passin "pass:$${VES_P12_PASSWORD}" -nocerts -nodes -legacy > "$KEY_FILE" 2>/dev/null
        CURL_AUTH=(--cert "$CERT_FILE" --key "$KEY_FILE")
      fi

      echo "Waiting for site $SITE_NAME to come ONLINE..."
      elapsed=0
      while true; do
        STATE=$(curl -s "$${CURL_AUTH[@]}" "$API_URL/config/namespaces/system/securemesh_site_v2s/$SITE_NAME" | \
          python3 -c "import sys,json; print(json.load(sys.stdin).get('spec',{}).get('site_state',''))" 2>/dev/null || echo "")
        if [ "$STATE" = "ONLINE" ]; then
          echo "Site is ONLINE."
          break
        fi
        if [ "$elapsed" -ge "$MAX_WAIT" ]; then
          echo "WARNING: Site not ONLINE after $${MAX_WAIT}s. Skipping public IP update."
          exit 0
        fi
        echo "  State: $STATE ($${elapsed}s elapsed)"
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
      done

      # GET current config, update public_ip on the node, PUT back.
      # Retry on RESOURCE_VERSION_MISMATCH — the CE updates the object frequently.
      MAX_RETRIES=10
      for attempt in $(seq 1 $MAX_RETRIES); do
        CURRENT=$(curl -s "$${CURL_AUTH[@]}" "$API_URL/config/namespaces/system/securemesh_site_v2s/$SITE_NAME")

        UPDATED=$(echo "$CURRENT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for cloud in ['aws','azure','kvm','vmware','baremetal']:
    nm = d.get('spec',{}).get(cloud,{}).get('not_managed',{})
    nodes = nm.get('node_list',[])
    if nodes:
        nodes[0]['public_ip'] = '$PUBLIC_IP'
        break
body = {
    'metadata': {
        'name': d['metadata']['name'],
        'namespace': d['metadata']['namespace'],
        'labels': d['metadata']['labels'],
        'description': d['metadata'].get('description',''),
        'annotations': d['metadata'].get('annotations', {}),
        'disable': d['metadata'].get('disable', False)
    },
    'resource_version': d['resource_version'],
    'spec': d['spec']
}
print(json.dumps(body))
")

        RESULT=$(echo "$UPDATED" | curl -s -X PUT "$${CURL_AUTH[@]}" \
          -H "Content-Type: application/json" \
          "$API_URL/config/namespaces/system/securemesh_site_v2s/$SITE_NAME" \
          -d @-)

        if echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('code') == 10 else 1)" 2>/dev/null; then
          echo "  Resource version conflict, retrying ($attempt/$MAX_RETRIES)..."
          sleep 2
          continue
        fi

        if echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'code' not in d else 1)" 2>/dev/null; then
          echo "Public IP $PUBLIC_IP set on site $SITE_NAME"
        else
          echo "WARNING: Failed to set public IP: $(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message','unknown'))" 2>/dev/null)"
        fi
        break
      done
    SCRIPT
  }

  depends_on = [
    volterra_securemesh_site_v2.this,
    azurerm_linux_virtual_machine.ce,
  ]
}

# -----------------------------------------------------------------------------
# Set network segment on SLI interface after site registration.
# -----------------------------------------------------------------------------

resource "terraform_data" "set_segment_interface" {
  count = var.segment_name != null ? 1 : 0

  triggers_replace = [var.segment_name]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      F5XC_API_TOKEN = var.f5xc_api_token != null ? var.f5xc_api_token : ""
    }
    command = <<-SCRIPT
      set -euo pipefail

      API_URL="${var.f5xc_api_url}"
      P12_FILE="${var.f5xc_api_p12_file}"
      SITE_NAME="${volterra_securemesh_site_v2.this.name}"
      SEGMENT_NAME="${var.segment_name}"
      MAX_WAIT=3600
      POLL_INTERVAL=30

      # --- Auth: prefer API token, fall back to P12 cert ---
      if [ -n "$${F5XC_API_TOKEN:-}" ]; then
        CURL_AUTH=(-H "Authorization: APIToken $F5XC_API_TOKEN")
      else
        CERT_FILE=$(mktemp) KEY_FILE=$(mktemp)
        trap "rm -f $CERT_FILE $KEY_FILE" EXIT
        openssl pkcs12 -in "$P12_FILE" -passin "pass:$${VES_P12_PASSWORD}" -clcerts -nokeys -legacy > "$CERT_FILE" 2>/dev/null
        openssl pkcs12 -in "$P12_FILE" -passin "pass:$${VES_P12_PASSWORD}" -nocerts -nodes -legacy > "$KEY_FILE" 2>/dev/null
        CURL_AUTH=(--cert "$CERT_FILE" --key "$KEY_FILE")
      fi

      echo "Waiting for site $SITE_NAME to come ONLINE..."
      elapsed=0
      while true; do
        STATE=$(curl -s "$${CURL_AUTH[@]}" "$API_URL/config/namespaces/system/securemesh_site_v2s/$SITE_NAME" | \
          python3 -c "import sys,json; print(json.load(sys.stdin).get('spec',{}).get('site_state',''))" 2>/dev/null || echo "")
        if [ "$STATE" = "ONLINE" ]; then
          echo "Site is ONLINE."
          break
        fi
        if [ "$elapsed" -ge "$MAX_WAIT" ]; then
          echo "WARNING: Site not ONLINE after $${MAX_WAIT}s. Skipping segment config."
          exit 0
        fi
        echo "  State: $STATE ($${elapsed}s elapsed)"
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
      done

      # GET current config, set segment on SLI interface, PUT back.
      # Retry on RESOURCE_VERSION_MISMATCH — the CE updates the object frequently.
      MAX_RETRIES=10
      for attempt in $(seq 1 $MAX_RETRIES); do
        CURRENT=$(curl -s "$${CURL_AUTH[@]}" "$API_URL/config/namespaces/system/securemesh_site_v2s/$SITE_NAME")

        UPDATED=$(echo "$CURRENT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
segment_name = '$SEGMENT_NAME'
tenant = d.get('system_metadata',{}).get('tenant', '')
for cloud in ['aws','azure','kvm','vmware','baremetal']:
    nm = d.get('spec',{}).get(cloud,{}).get('not_managed',{})
    nodes = nm.get('node_list',[])
    if nodes:
        ifaces = nodes[0].get('interface_list',[])
        # SLI is the second interface (index 1)
        if len(ifaces) > 1:
            ifaces[1]['network_option'] = {
                'segment_network': {
                    'name': segment_name,
                    'namespace': 'system',
                    'tenant': tenant
                }
            }
            ifaces[1]['site_to_site_connectivity_interface_enabled'] = {}
        break
body = {
    'metadata': {
        'name': d['metadata']['name'],
        'namespace': d['metadata']['namespace'],
        'labels': d['metadata']['labels'],
        'description': d['metadata'].get('description',''),
        'annotations': d['metadata'].get('annotations', {}),
        'disable': d['metadata'].get('disable', False)
    },
    'resource_version': d['resource_version'],
    'spec': d['spec']
}
print(json.dumps(body))
")

        RESULT=$(echo "$UPDATED" | curl -s -X PUT "$${CURL_AUTH[@]}" \
          -H "Content-Type: application/json" \
          "$API_URL/config/namespaces/system/securemesh_site_v2s/$SITE_NAME" \
          -d @-)

        if echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('code') == 10 else 1)" 2>/dev/null; then
          echo "  Resource version conflict, retrying ($attempt/$MAX_RETRIES)..."
          sleep 2
          continue
        fi

        if echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'code' not in d else 1)" 2>/dev/null; then
          echo "Segment '$SEGMENT_NAME' configured on SLI interface for site $SITE_NAME"
        else
          echo "WARNING: Failed to set segment: $(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message','unknown'))" 2>/dev/null)"
        fi
        break
      done
    SCRIPT
  }

  depends_on = [
    volterra_securemesh_site_v2.this,
    azurerm_linux_virtual_machine.ce,
    terraform_data.push_upgrades,
  ]
}

# -----------------------------------------------------------------------------
# Push available OS and SW updates after site is configured.
# Uses the /sites/ (not /securemesh_site_v2s/) endpoint for upgrade operations.
# -----------------------------------------------------------------------------

resource "terraform_data" "push_upgrades" {
  triggers_replace = [volterra_securemesh_site_v2.this.name]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      F5XC_API_TOKEN = var.f5xc_api_token != null ? var.f5xc_api_token : ""
    }
    command = <<-SCRIPT
      set -euo pipefail

      API_URL="${var.f5xc_api_url}"
      P12_FILE="${var.f5xc_api_p12_file}"
      SITE_NAME="${volterra_securemesh_site_v2.this.name}"

      # --- Auth: prefer API token, fall back to P12 cert ---
      if [ -n "$${F5XC_API_TOKEN:-}" ]; then
        CURL_AUTH=(-H "Authorization: APIToken $F5XC_API_TOKEN")
      else
        CERT_FILE=$(mktemp) KEY_FILE=$(mktemp)
        trap "rm -f $CERT_FILE $KEY_FILE" EXIT
        openssl pkcs12 -in "$P12_FILE" -passin "pass:$${VES_P12_PASSWORD}" -clcerts -nokeys -legacy > "$CERT_FILE" 2>/dev/null
        openssl pkcs12 -in "$P12_FILE" -passin "pass:$${VES_P12_PASSWORD}" -nocerts -nodes -legacy > "$KEY_FILE" 2>/dev/null
        CURL_AUTH=(--cert "$CERT_FILE" --key "$KEY_FILE")
      fi

      # Wait for available_version to be populated (node must finish registering)
      echo "Waiting for upgrade info to appear for $SITE_NAME (up to 10 min)..."
      MAX_WAIT=600
      ELAPSED=0
      OS_VERSION=""
      SW_VERSION=""

      while [ $ELAPSED -lt $MAX_WAIT ]; do
        SITE_DATA=$(curl -s "$${CURL_AUTH[@]}" "$API_URL/config/namespaces/system/sites/$SITE_NAME")

        OS_VERSION=$(echo "$SITE_DATA" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('status', []):
    os_st = s.get('operating_system_status') or {}
    avail = os_st.get('available_version', '')
    if avail:
        current = ((os_st.get('deployment_state') or {}).get('version', ''))
        if avail != current:
            print(avail)
            break
" 2>/dev/null || echo "")

        SW_VERSION=$(echo "$SITE_DATA" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('status', []):
    sw_st = s.get('volterra_software_status') or {}
    avail = sw_st.get('available_version', '')
    if avail:
        current = ((sw_st.get('deployment_state') or {}).get('version', ''))
        if avail != current:
            print(avail)
            break
" 2>/dev/null || echo "")

        if [ -n "$OS_VERSION" ] || [ -n "$SW_VERSION" ]; then
          echo "Upgrade info available after $${ELAPSED}s"
          break
        fi

        # Also check if versions are current (no upgrade needed)
        HAS_STATUS=$(echo "$SITE_DATA" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('status', []):
    os_st = s.get('operating_system_status') or {}
    sw_st = s.get('volterra_software_status') or {}
    os_dep = (os_st.get('deployment_state') or {}).get('version', '')
    sw_dep = (sw_st.get('deployment_state') or {}).get('version', '')
    if os_dep or sw_dep:
        print('yes')
        break
" 2>/dev/null || echo "")

        if [ "$HAS_STATUS" = "yes" ] && [ -z "$OS_VERSION" ] && [ -z "$SW_VERSION" ]; then
          echo "Site already on latest versions after $${ELAPSED}s"
          break
        fi

        sleep 30
        ELAPSED=$((ELAPSED + 30))
        echo "  Still waiting... ($${ELAPSED}s)"
      done

      if [ $ELAPSED -ge $MAX_WAIT ] && [ -z "$OS_VERSION" ] && [ -z "$SW_VERSION" ]; then
        echo "WARNING: Timed out waiting for upgrade info. Site may still be bootstrapping."
      fi

      # Push OS upgrade if available
      if [ -n "$OS_VERSION" ]; then
        echo "OS update available: $OS_VERSION — pushing upgrade..."
        RESULT=$(curl -s -X POST "$${CURL_AUTH[@]}" \
          -H "Content-Type: application/json" \
          "$API_URL/config/namespaces/system/sites/$SITE_NAME/upgrade_os" \
          -d "{\"version\":\"$OS_VERSION\"}")
        echo "OS upgrade response: $RESULT"
      else
        echo "No OS update available for $SITE_NAME"
      fi

      # Push SW upgrade if available
      if [ -n "$SW_VERSION" ]; then
        echo "SW update available: $SW_VERSION — pushing upgrade..."
        RESULT=$(curl -s -X POST "$${CURL_AUTH[@]}" \
          -H "Content-Type: application/json" \
          "$API_URL/config/namespaces/system/sites/$SITE_NAME/upgrade_sw" \
          -d "{\"version\":\"$SW_VERSION\"}")
        echo "SW upgrade response: $RESULT"
      else
        echo "No SW update available for $SITE_NAME"
      fi
    SCRIPT
  }

  depends_on = [
    volterra_securemesh_site_v2.this,
    azurerm_linux_virtual_machine.ce,
    terraform_data.set_public_ip,
  ]
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
