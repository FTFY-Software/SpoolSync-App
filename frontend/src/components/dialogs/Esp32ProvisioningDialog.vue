<template>
  <v-dialog :model-value="modelValue" max-width="520" @update:model-value="$emit('update:modelValue', $event)">
    <v-card rounded="xl">
      <v-card-title class="pa-4 pb-2">
        <v-icon class="mr-2">mdi-chip</v-icon>
        Provision ESP32 Device
      </v-card-title>

      <v-card-text>
        <v-alert v-if="!serialSupported" type="warning" variant="tonal" class="mb-4">
          Web Serial API is not supported in this browser. Use Chrome or Edge.
        </v-alert>

        <v-stepper v-model="step" :items="steps" flat hide-actions>
          <template #item.1>
            <v-form @submit.prevent>
              <v-text-field
                v-model="form.deviceName"
                label="Device Name"
                variant="outlined"
                density="compact"
                class="mb-2"
                :disabled="busy"
              />
              <v-text-field
                v-model="form.ssid"
                label="WiFi SSID"
                variant="outlined"
                density="compact"
                class="mb-2"
                :disabled="busy"
              />
              <v-text-field
                v-model="form.password"
                label="WiFi Password"
                type="password"
                variant="outlined"
                density="compact"
                class="mb-2"
                :disabled="busy"
              />
              <v-text-field
                v-model="form.host"
                label="SpoolSync Hostname (e.g. spoolsync.local)"
                variant="outlined"
                density="compact"
                class="mb-1"
                :disabled="busy"
              />
              <v-checkbox
                v-model="saveWifi"
                label="Remember WiFi details in this browser"
                density="compact"
                hide-details
                :disabled="busy"
              />
            </v-form>
          </template>

          <template #item.2>
            <div class="d-flex flex-column align-center py-4 gap-3">
              <v-progress-circular v-if="busy" indeterminate size="48" color="primary" />
              <v-icon v-else-if="provisionSuccess" size="48" color="success">mdi-check-circle</v-icon>
              <v-icon v-else size="48" color="error">mdi-close-circle</v-icon>
              <div class="text-body-1">{{ statusMessage }}</div>
            </div>
          </template>
        </v-stepper>

        <v-alert v-if="errorMessage" type="error" variant="tonal" class="mt-3">
          {{ errorMessage }}
        </v-alert>
      </v-card-text>

      <v-card-actions class="pa-4 pt-0">
        <v-spacer />
        <v-btn @click="close">{{ provisionSuccess ? 'Done' : 'Cancel' }}</v-btn>
        <v-btn
          v-if="step === 1"
          color="primary"
          :loading="busy"
          :disabled="!serialSupported || !form.deviceName || !form.ssid || !form.host"
          @click="startProvisioning"
        >
          Connect &amp; Provision
        </v-btn>
      </v-card-actions>
    </v-card>
  </v-dialog>
</template>

<script setup>
import { ref, reactive, computed, onMounted } from 'vue';
import apiClient from '@/services/apiClient';

defineProps({ modelValue: { type: Boolean, default: false } });
const emit = defineEmits(['update:modelValue', 'provisioned']);

const serialSupported = computed(() => 'serial' in navigator);

const step = ref(1);
const busy = ref(false);
const provisionSuccess = ref(false);
const statusMessage = ref('');
const errorMessage = ref('');
const saveWifi = ref(false);

const steps = ['Configure', 'Provisioning'];

const form = reactive({
  deviceName: '',
  ssid: '',
  password: '',
  host: window.location.hostname,
});

// Server-configured host (ESP32_SERVER_HOST) wins over the address-bar
// hostname, which devices may not be able to resolve (e.g. behind a proxy).
const defaultHost = ref(window.location.hostname);

const LS_SSID_KEY = 'spoolsync:wifi:ssid';
const LS_PASS_KEY = 'spoolsync:wifi:password';

onMounted(() => {
  fetch('/api/client-config').then(r => r.json()).then(data => {
    if (!data.esp32ServerHost) return;
    if (form.host === defaultHost.value) form.host = data.esp32ServerHost;
    defaultHost.value = data.esp32ServerHost;
  }).catch(() => {});

  const savedSsid = localStorage.getItem(LS_SSID_KEY);
  const savedPass = localStorage.getItem(LS_PASS_KEY);
  if (savedSsid !== null) {
    form.ssid = savedSsid;
    form.password = savedPass ?? '';
    saveWifi.value = true;
  }
});

function generateUuid() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  });
}

async function startProvisioning() {
  errorMessage.value = '';
  busy.value = true;
  step.value = 2;
  statusMessage.value = 'Connecting to device via serial…';

  const uniqueDeviceId = generateUuid();
  let port = null;

  try {
    // Register in SpoolSync FIRST so /report calls succeed as soon as
    // the ESP32 connects to WiFi (which happens immediately after provisioning)
    statusMessage.value = 'Registering device in SpoolSync…';
    const regRes = await apiClient.post('/esp32-devices', {
      name: form.deviceName,
      uniqueDeviceId,
    });
    const registeredDeviceId = regRes.data.deviceId;

    port = await navigator.serial.requestPort();
    await port.open({ baudRate: 115200 });

    statusMessage.value = 'Sending configuration…';

    if (saveWifi.value) {
      localStorage.setItem(LS_SSID_KEY, form.ssid);
      localStorage.setItem(LS_PASS_KEY, form.password);
    } else {
      localStorage.removeItem(LS_SSID_KEY);
      localStorage.removeItem(LS_PASS_KEY);
    }

    const writer = port.writable.getWriter();
    const payload = JSON.stringify({
      ssid: form.ssid,
      password: form.password,
      deviceId: uniqueDeviceId,
      host: form.host,
    }) + '\n';
    await writer.write(new TextEncoder().encode(payload));
    writer.releaseLock();

    statusMessage.value = 'Waiting for response…';

    const reader = port.readable.getReader();
    let response = '';
    const timeout = Date.now() + 20000;
    // Keep reading until we see the success marker or time out.
    // The device emits many debug lines (HX711 readings, WiFi status, etc.)
    // while reconnecting — we must not stop at the first newline.
    while (Date.now() < timeout) {
      const { value, done } = await reader.read();
      if (done) break;
      response += new TextDecoder().decode(value);
      if (response.includes(': 200 ') || /\bOK\b/.test(response)) break;
    }
    reader.releaseLock();
    await port.close();

    const success = response.includes(': 200 ') || /\bOK\b/.test(response);
    const trimmed = response.trim();
    if (!success) {
      // Clean up the pre-registered device if the ESP32 didn't accept config
      await apiClient.delete(`/esp32-devices/${uniqueDeviceId}`).catch(() => {});
      throw new Error(`Device responded: ${trimmed || 'no response'}`);
    }

    provisionSuccess.value = true;
    statusMessage.value = 'Device provisioned successfully!';
    emit('provisioned', registeredDeviceId);
  } catch (err) {
    if (port) {
      try { await port.close(); } catch { /* ignore */ }
    }
    provisionSuccess.value = false;
    statusMessage.value = 'Provisioning failed.';
    errorMessage.value = err.message;
    step.value = 1;
  } finally {
    busy.value = false;
  }
}

function close() {
  emit('update:modelValue', false);
  step.value = 1;
  provisionSuccess.value = false;
  statusMessage.value = '';
  errorMessage.value = '';
  form.deviceName = '';
  form.host = defaultHost.value;
  if (!saveWifi.value) {
    form.ssid = '';
    form.password = '';
  }
}
</script>
