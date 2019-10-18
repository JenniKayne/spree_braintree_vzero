# frozen_string_literal: true

module Spree
  class BraintreeCheckout < ActiveRecord::Base
    scope :in_state, ->(state) { where(state: state) }
    scope :not_in_state, ->(state) { where.not(state: state) }
    scope :recent_with_paypal, lambda {
                                 where(created_at: 2.days.ago..Time.now,
                                       state: 'settled')
                                   .where.not(paypal_email: nil)
                               }

    after_commit :update_payment_and_order

    FINAL_STATES = %w[authorization_expired processor_declined gateway_rejected failed voided settled settlement_declined refunded released].freeze

    has_one :payment, foreign_key: :source_id, as: :source, class_name: 'Spree::Payment'
    has_one :order, through: :payment

    def self.create_from_params(params)
      type = braintree_card_type_to_spree(params[:braintree_card_type])
      create!(paypal_email: params[:paypal_email],
              braintree_last_digits: params[:braintree_last_two],
              braintree_card_type: type)
    end

    def self.create_from_token(token, payment_method_id)
      gateway = Spree::PaymentMethod.find(payment_method_id)
      vaulted_payment_method = gateway.vaulted_payment_method(token)
      type = braintree_card_type_to_spree(vaulted_payment_method.try(:card_type))
      create!(paypal_email: vaulted_payment_method.try(:email),
              braintree_last_digits: vaulted_payment_method.try(:last_4),
              braintree_card_type: type)
    end

    def self.update_states
      braintree = Gateway::BraintreeVzeroBase.first.provider
      result = { changed: 0, unchanged: 0 }
      not_in_state(FINAL_STATES).find_each do |checkout|
        checkout.state = fetch_braintree_checkout_status
        if checkout.state_changed?
          result[:changed] += 1
          checkout.save
        else
          result[:unchanged] += 1
        end
      end
      complete_failed_orders_with_settled_checkout(recent_with_paypal)
      result
    end

    # Some orders take too long to authorize and fail settlement on Spree,
    # this part of the job checks for the recent checkouts to complete them.
    def complete_failed_orders_with_settled_checkout(recent_paypal_checkouts)
      recent_paypal_checkouts.each do |checkout|
        next unless checkout.failed_order_and_settled_checkout?

        # Confirm the checkout is settled on Braintree.
        transaction_status = checkout.fetch_braintree_checkout_status
        order_payment = checkout.order.payments.find_by(state: 'failed')
        order_payment.state = 'pending' if transaction_status == 'settled'
        order_payment.save!
        # Mark complete if all the payment amounts match.
        order_payment.state = 'completed' if [checkout.order.total,
                                              checkout.payment.amount,
                                              checkout.fetch_braintree_checkout_amount].uniq.length == 1
        order_payment.save!
        checkout.order.sync_order_shipments
      end
    end

    def failed_order_and_settled_checkout?
      payment&.state == 'failed' && state == 'settled'
    end

    def fetch_braintree_checkout
      Gateway::BraintreeVzeroBase.first.provider::Transaction.find(transaction_id)
    end

    def fetch_braintree_checkout_status
      fetch_braintree_checkout.status
    end

    def fetch_braintree_checkout_amount
      fetch_braintree_checkout.amount
    end

    def update_state
      status = Transaction.new(Gateway::BraintreeVzeroBase.first.provider, transaction_id).status
      payment.send(payment_action(status))
      status
    end

    def settled?; end

    def actions
      %w[void settle credit]
    end

    def can_void?(_payment)
      %w[authorized submitted_for_settlement].include? state
    end

    def can_settle?(_)
      %w[authorized].include? state
    end

    def can_credit?(_payment)
      %w[settled settling].include? state
    end

    private

    def update_payment_and_order
      return unless (changes = previous_changes[:state])
      return unless changes[0] != changes[1]
      return unless payment

      utils = Gateway::BraintreeVzeroBase::Utils.new(Gateway::BraintreeVzeroBase.first, order)
      payment_state = utils.map_payment_status(state)
      payment.send(payment_action(payment_state))
    end

    def self.braintree_card_type_to_spree(type)
      return '' unless type

      case type
      when 'AmericanExpress'
        'american_express'
      when 'Diners Club'
        'diners_club'
      when 'MasterCard'
        'master'
      else
        type.downcase
      end
    end

    def payment_action(state)
      case state
      when 'pending'
        'pend'
      when 'void'
        'void'
      when 'completed'
        'complete'
      else
        'failure'
      end
    end
  end
end
