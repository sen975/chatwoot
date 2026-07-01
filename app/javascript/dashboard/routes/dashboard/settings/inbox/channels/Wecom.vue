<script>
import { mapGetters } from 'vuex';
import { useVuelidate } from '@vuelidate/core';
import { useAlert } from 'dashboard/composables';
import { required, minLength, maxLength } from '@vuelidate/validators';
import router from '../../../../index';
import PageHeader from '../../SettingsSubPageHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

export default {
  components: {
    PageHeader,
    NextButton,
  },
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      channelName: '',
      corpId: '',
      openKfid: '',
      secret: '',
      token: '',
      encodingAesKey: '',
    };
  },
  computed: {
    ...mapGetters({
      uiFlags: 'inboxes/getUIFlags',
    }),
  },
  validations: {
    channelName: { required },
    corpId: { required },
    openKfid: { required },
    secret: { required },
    token: { required },
    encodingAesKey: {
      required,
      minLength: minLength(43),
      maxLength: maxLength(43),
    },
  },
  methods: {
    async createChannel() {
      this.v$.$touch();
      if (this.v$.$invalid) {
        return;
      }

      try {
        const wecomChannel = await this.$store.dispatch(
          'inboxes/createChannel',
          {
            name: this.channelName?.trim(),
            channel: {
              type: 'wecom',
              corp_id: this.corpId,
              open_kfid: this.openKfid,
              secret: this.secret,
              token: this.token,
              encoding_aes_key: this.encodingAesKey,
              agent_mappings: {},
            },
          }
        );

        router.replace({
          name: 'settings_inboxes_add_agents',
          params: {
            page: 'new',
            inbox_id: wecomChannel.id,
          },
        });
      } catch (error) {
        useAlert(this.$t('INBOX_MGMT.ADD.WECOM_CHANNEL.API.ERROR_MESSAGE'));
      }
    },
  },
};
</script>

<template>
  <div class="h-full w-full p-6 col-span-6">
    <PageHeader
      :header-title="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.TITLE')"
      :header-content="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.DESC')"
    />
    <form
      class="flex flex-wrap flex-col mx-0"
      @submit.prevent="createChannel()"
    >
      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.channelName.$error }">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.CHANNEL_NAME.LABEL') }}
          <input
            v-model="channelName"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.WECOM_CHANNEL.CHANNEL_NAME.PLACEHOLDER')
            "
            @blur="v$.channelName.$touch"
          />
          <span v-if="v$.channelName.$error" class="message">{{
            $t('INBOX_MGMT.ADD.WECOM_CHANNEL.CHANNEL_NAME.ERROR')
          }}</span>
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.corpId.$error }">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.CORP_ID.LABEL') }}
          <input
            v-model="corpId"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.WECOM_CHANNEL.CORP_ID.PLACEHOLDER')
            "
            @blur="v$.corpId.$touch"
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.openKfid.$error }">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.OPEN_KFID.LABEL') }}
          <input
            v-model="openKfid"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.WECOM_CHANNEL.OPEN_KFID.PLACEHOLDER')
            "
            @blur="v$.openKfid.$touch"
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.secret.$error }">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.SECRET.LABEL') }}
          <input
            v-model="secret"
            type="text"
            :placeholder="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.SECRET.PLACEHOLDER')"
            @blur="v$.secret.$touch"
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.token.$error }">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.TOKEN.LABEL') }}
          <input
            v-model="token"
            type="text"
            :placeholder="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.TOKEN.PLACEHOLDER')"
            @blur="v$.token.$touch"
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.encodingAesKey.$error }">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.ENCODING_AES_KEY.LABEL') }}
          <input
            v-model="encodingAesKey"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.WECOM_CHANNEL.ENCODING_AES_KEY.PLACEHOLDER')
            "
            @blur="v$.encodingAesKey.$touch"
          />
        </label>
      </div>

      <div class="w-full mt-4">
        <NextButton
          :is-loading="uiFlags.isCreating"
          type="submit"
          solid
          blue
          :label="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.SUBMIT_BUTTON')"
        />
      </div>
    </form>
  </div>
</template>
