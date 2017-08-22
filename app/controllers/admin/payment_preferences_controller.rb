class Admin::PaymentPreferencesController < Admin::AdminBaseController
  before_action :ensure_payments_enabled

  def index
    more_locals = {}

    if @paypal_enabled
      more_locals.merge!(paypal_index)
    end

    if @stripe_available || @stripe_enabled
      more_locals.merge!(stripe_index)
    end

    more_locals.merge!(build_prefs_form)
    view_locals = build_view_locals.merge(more_locals)

    stripe_connected =  view_locals[:stripe_enabled] && view_locals[:stripe_account] && view_locals[:stripe_account][:api_verified]
    paypal_connected =  view_locals[:paypal_enabled] && view_locals[:paypal_account].present?

    payment_locals = {
      stripe_connected: stripe_connected,
      paypal_connected: paypal_connected,
      payments_connected: stripe_connected || paypal_connected,
      stripe_allowed:  StripeHelper.stripe_allows_country_and_currency?(@current_community.country, @current_community.currency),
      paypal_allowed:  PaypalHelper.paypal_allows_country_and_currency?(@current_community.country, @current_community.currency),
      stripe_ready: StripeHelper.community_ready_for_payments?(@current_community.id),
      paypal_ready: PaypalHelper.community_ready_for_payments?(@current_community.id),
    }

    render 'index', locals: view_locals.merge(payment_locals)
  end

  def update
    if params[:payment_preferences_form].present?
      update_payment_preferences
    elsif params[:stripe_api_keys_form].present? && @stripe_available
      update_stripe_keys
    end

    redirect_to action: :index
  end

  private

  MIN_COMMISSION_PERCENTAGE = 0
  MAX_COMMISSION_PERCENTAGE = 100

  def ensure_payments_enabled
    @paypal_enabled = PaypalHelper.paypal_active?(@current_community.id)
    @stripe_available = StripeHelper.stripe_feature_enabled?(@current_community.id)
    @stripe_enabled = StripeHelper.stripe_provisioned?(@current_community.id)
    unless @paypal_enabled || @stripe_enabled
      flash[:error] = t("admin.communities.settings.payments_not_enabled")
      redirect_to admin_details_edit_path
    end
  end

  def paypal_index
    paypal_account = paypal_accounts_api.get(community_id: @current_community.id).data

    {
      order_permission_action: admin_paypal_preferences_account_create_path(),
      paypal_account: paypal_account
    }
  end

  def stripe_index
    stripe_account = stripe_tx_settings
    {
      stripe_account: stripe_account,
      stripe_api_form: StripeApiKeysForm.new
    }
  end

  def paypal_tx_settings
    Maybe(tx_settings_api.get(community_id: @current_community.id, payment_gateway: :paypal, payment_process: :preauthorize))
    .select { |result| result[:success] }
    .map { |result| result[:data] }
    .or_else({})
  end

  def stripe_tx_settings
    Maybe(tx_settings_api.get(community_id: @current_community.id, payment_gateway: :stripe, payment_process: :preauthorize))
    .select { |result| result[:success] }
    .map { |result| result[:data] }
    .or_else({})
  end

  def active_tx_setttings
    if @paypal_enabled
      paypal_tx_settings
    else
      stripe_tx_settings
    end
  end

  def build_prefs_form(params = nil)
    currency = @current_community.currency

    if @paypal_enabled
      minimum_commission = paypal_minimum_commissions_api.get(currency)
      tx_settings = paypal_tx_settings
    else
      minimum_commission = 0
      tx_settings = stripe_tx_settings
    end

    form = PaymentPreferencesForm.new(
      minimum_commission: minimum_commission,
      commission_from_seller: tx_settings[:commission_from_seller],
      minimum_listing_price: Money.new(tx_settings[:minimum_price_cents], currency),
      minimum_transaction_fee: Money.new(tx_settings[:minimum_transaction_fee_cents], currency),
      marketplace_currency: currency
    )
    {payment_prefs_form: form, payment_prefs_valid: form.valid? }
  end

  def build_view_locals
    @selected_left_navi_link = "payment_preferences"

    onboarding_popup_locals = OnboardingViewUtils.popup_locals(
      flash[:show_onboarding_popup],
      admin_getting_started_guide_path,
      Admin::OnboardingWizard.new(@current_community.id).setup_status)

    view_locals = {
      min_commission_percentage: MIN_COMMISSION_PERCENTAGE,
      max_commission_percentage: MAX_COMMISSION_PERCENTAGE,
      available_currencies: MarketplaceService::AvailableCurrencies::CURRENCIES,
      currency: @current_community.currency,
      display_knowledge_base_articles: APP_CONFIG.display_knowledge_base_articles,
      knowledge_base_url: APP_CONFIG.knowledge_base_url,
      support_email: APP_CONFIG.support_email,
      stripe_enabled: @stripe_enabled || @stripe_available,
      paypal_enabled: @paypal_enabled,
      stripe_account: nil,
      paypal_account: nil,
      country_name: ISO3166::Country[@current_community.country].local_name
    }

    onboarding_popup_locals.merge(view_locals)
  end

  PaymentPreferencesForm = FormUtils.define_form("PaymentPreferencesForm",
    :commission_from_seller,
    :minimum_listing_price,
    :minimum_commission,
    :minimum_transaction_fee,
    :marketplace_currency,
    :mode
    ).with_validations do
      validates_numericality_of(
        :commission_from_seller,
        only_integer: true,
        allow_nil: false,
        greater_than_or_equal_to: MIN_COMMISSION_PERCENTAGE,
        less_than_or_equal_to: MAX_COMMISSION_PERCENTAGE,
        if: proc { mode == 'transaction_fee' }
      )

      available_currencies = MarketplaceService::AvailableCurrencies::CURRENCIES
      validates_inclusion_of(:marketplace_currency, in: available_currencies)

      validate do |prefs|
        if minimum_listing_price.nil? || minimum_listing_price < minimum_commission
          prefs.errors[:base] << I18n.t("admin.paypal_accounts.minimum_listing_price_below_min",
                                        { minimum_commission: minimum_commission })
        elsif minimum_transaction_fee && minimum_listing_price < minimum_transaction_fee
          prefs.errors[:base] << I18n.t("admin.paypal_accounts.minimum_listing_price_below_tx_fee",
                                        { minimum_transaction_fee: minimum_transaction_fee })
        end
      end
    end

  def update_payment_preferences
    currency = params[:payment_preferences_form]["marketplace_currency"] || @current_community.currency

    minimum_commission = @paypal_enabled ? paypal_minimum_commissions_api.get(currency) : 0

    form = PaymentPreferencesForm.new(parse_preferences(params[:payment_preferences_form], currency).merge(minimum_commission: minimum_commission))
    if form.valid?
      ActiveRecord::Base.transaction do
        @current_community.currency = currency
        @current_community.save!

        base_params = {community_id: @current_community.id,
                       payment_process: :preauthorize,
                       commission_from_seller: form.commission_from_seller,
                       minimum_price_cents: form.minimum_listing_price.try(:cents),
                       minimum_price_currency: currency,
                       minimum_transaction_fee_cents: form.minimum_transaction_fee.try(:cents),
                       minimum_transaction_fee_currency: currency}.compact

        if paypal_tx_settings.present?
          tx_settings_api.update(base_params.merge(payment_gateway: :paypal))
        end
        if stripe_tx_settings.present?
          tx_settings_api.update(base_params.merge(payment_gateway: :stripe))
        end
      end

      if form.mode == 'transaction_fee'
        # Onboarding wizard step recording
        state_changed = Admin::OnboardingWizard.new(@current_community.id)
          .update_from_event(:payment_preferences_updated, @current_community)
        if state_changed
          report_to_gtm([{event: "km_record", km_event: "Onboarding payments setup"},
                         {event: "km_record", km_event: "Onboarding paypal connected"}])

          flash[:show_onboarding_popup] = true
        end
        flash[:notice] = t("admin.payment_preferences.transaction_fee_settings_updated")
      else
        flash[:notice] = t("admin.payment_preferences.general_settings_updated")
      end
    else
      flash[:error] = form.errors.full_messages.join(", ")
    end
  end

  def paypal_minimum_commissions_api
    PaypalService::API::Api.minimum_commissions
  end

  def tx_settings_api
    TransactionService::API::Api.settings
  end

  def paypal_accounts_api
    PaypalService::API::Api.accounts
  end

  def parse_money_with_default(str_value, default, currency)
    str_value.present? ? MoneyUtil.parse_str_to_money(str_value, currency) : default.present? ? Money.new(default.to_i, currency) : nil
  end

  def parse_preferences(params, currency)
    tx_settings = active_tx_setttings
    tx_fee =  parse_money_with_default(params[:minimum_transaction_fee], tx_settings[:minimum_transaction_fee_cents], currency)
    tx_commission = params[:commission_from_seller] || tx_settings[:commission_from_seller]
    tx_commission = tx_commission.present? ? tx_commission.to_i : nil
    tx_min_price = parse_money_with_default(params[:minimum_listing_price], tx_settings[:minimum_price_cents], currency)

    {
      minimum_listing_price: tx_min_price,
      minimum_transaction_fee: tx_fee,
      commission_from_seller: tx_commission,
      marketplace_currency: currency,
      mode: params[:mode],
    }
  end

  StripeApiKeysForm = FormUtils.define_form("StripeApiKeysForm",
    :api_private_key,
    :api_publishable_key).with_validations do
    validates_format_of :api_private_key, with: Regexp.new(APP_CONFIG.stripe_private_key_pattern)
    validates_format_of :api_publishable_key, with: Regexp.new(APP_CONFIG.stripe_publishable_key_pattern)
  end

  def update_stripe_keys
    api_form = StripeApiKeysForm.new(params[:stripe_api_keys_form])
    if api_form.valid? && api_form.api_private_key.present?
      if !@stripe_enabled
        tx_settings_api.provision({ community_id: @current_community.id,
                                    payment_process: :preauthorize,
                                    payment_gateway: :stripe,
                                    api_private_key: api_form.api_private_key,
                                    api_publishable_key: api_form.api_publishable_key
                                   })
      else
        tx_settings_api.update({ community_id: @current_community.id,
                                 payment_process: :preauthorize,
                                 payment_gateway: :stripe,
                                 api_private_key: api_form.api_private_key,
                                 api_publishable_key: api_form.api_publishable_key
                                })
      end
      if stripe_api.check_balance(community: @current_community.id)
        tx_settings_api.api_verified(community_id: @current_community.id, payment_gateway: :stripe, payment_process: :preauthorize)
        tx_settings_api.activate(community_id: @current_community.id, payment_gateway: :stripe, payment_process: :preauthorize)
        flash[:notice] = t("admin.payment_preferences.stripe_verified")
      else
        tx_settings_api.disable(community_id: @current_community.id, payment_gateway: :stripe, payment_process: :preauthorize)
        flash[:error] = t("admin.payment_preferences.invalid_api_keys")
      end
    else
      flash[:error] = t("admin.payment_preferences.missing_api_keys")
    end
  end

  def stripe_api
    StripeService::API::Api.wrapper
  end
end
