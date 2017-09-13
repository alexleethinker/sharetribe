# == Schema Information
#
# Table name: stripe_accounts
#
#  id                  :integer          not null, primary key
#  person_id           :string(255)
#  community_id        :integer
#  stripe_seller_id    :string(255)
#  first_name          :string(255)
#  last_name           :string(255)
#  address_country     :string(255)
#  address_city        :string(255)
#  address_line1       :string(255)
#  address_postal_code :string(255)
#  address_state       :string(255)
#  birth_date          :date
#  tos_date            :datetime
#  tos_ip              :string(255)
#  stripe_bank_id      :string(255)
#  bank_account_last_4 :string(255)
#  stripe_customer_id  :string(255)
#  stripe_source_info  :string(255)
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#

class StripeAccount < ApplicationRecord

  belongs_to :customer
  belongs_to :community

end
