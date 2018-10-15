# frozen_string_literal: true

require 'spec_helper'

module Spree
  describe 'Api Feature Specs', type: :request do
    before { Spree::Api::Config[:requires_authentication] = false }
    let!(:promotion) { FactoryBot.create(:promotion, :with_order_adjustment, code: 'foo', weighted_order_adjustment_amount: 10) }
    let(:promotion_code) { promotion.codes.first }
    let!(:store) { FactoryBot.create(:store) }
    let(:bill_address) { FactoryBot.create(:address) }
    let(:ship_address) { FactoryBot.create(:address) }
    let(:variant_1) { FactoryBot.create(:variant, price: 100.00) }
    let(:variant_2) { FactoryBot.create(:variant, price: 200.00) }
    let(:payment_method) { FactoryBot.create(:check_payment_method) }
    let!(:shipping_method) do
      FactoryBot.create(:shipping_method).tap do |shipping_method|
        shipping_method.zones.first.zone_members.create!(zoneable: ship_address.country)
        shipping_method.calculator.set_preference(:amount, 10.0)
      end
    end

    def parsed
      JSON.parse(response.body)
    end

    def login
      expect {
        post '/api/users', params: {
          user: {
            email: "featurecheckoutuser@example.com",
            password: "featurecheckoutuser"
          }
        }
      }.to change { Spree.user_class.count }.by 1
      expect(response).to have_http_status(:created)
      @user = Spree.user_class.find(parsed['id'])
      @user.create_new_auth_token
    end

    def create_order(order_headers: {}, order_params: {})
      expect {
        post '/api/orders', headers: order_headers, params: order_params
      }.to change { Order.count }.by 1
      expect(response).to have_http_status(:created)
      @order = Order.find(parsed['id'])
      expect(@order.email).to eq "featurecheckoutuser@example.com"
    end

    def update_order(order_params: {}, order_headers: {})
      put "/api/orders/#{@order.number}", headers: order_headers, params: order_params
      expect(response).to have_http_status(:ok)
    end

    def create_line_item(variant, quantity = 1, headers: {})
      expect {
        post "/api/orders/#{@order.number}/line_items",
          headers: headers, params: { line_item: { variant_id: variant.id, quantity: quantity } }
      }.to change { @order.line_items.count }.by 1
      expect(response).to have_http_status(:created)
    end

    def add_promotion(_promotion, headers: {})
      expect {
        put "/api/orders/#{@order.number}/apply_coupon_code",
          headers: headers, params: { coupon_code: promotion_code.value }
      }.to change { @order.promotions.count }.by 1
      expect(response).to have_http_status(:ok)
    end

    def add_address(address, billing: true, headers: {})
      address_type = billing ? :bill_address : :ship_address
      # It seems we are missing an order-scoped address api endpoint since we need
      # to use update here.
      expect {
        update_order(
          order_headers: headers,
          order_params: { order: { address_type => address.attributes.except('id') } },
        )
      }.to change { @order.reload.public_send(address_type) }.to address
    end

    def add_payment(headers: {})
      expect {
        post "/api/orders/#{@order.number}/payments",
          headers: headers, params: { payment: { payment_method_id: payment_method.id } }
      }.to change { @order.reload.payments.count }.by 1
      expect(response).to have_http_status(:created)
      expect(@order.payments.last.payment_method).to eq payment_method
    end

    def advance(headers: {})
      put "/api/checkouts/#{@order.number}/advance", headers: headers
      expect(response).to have_http_status(:ok)
    end

    def complete(headers: {})
      put "/api/checkouts/#{@order.number}/complete", headers: headers
      expect(response).to have_http_status(:ok)
    end

    def assert_order_expectations
      @order.reload
      expect(@order.state).to eq 'complete'
      expect(@order.completed_at).to be_a ActiveSupport::TimeWithZone
      expect(@order.item_total).to eq 600.00
      expect(@order.total).to eq 600.00
      expect(@order.adjustment_total).to eq(-10.00)
      expect(@order.shipment_total).to eq 10.00
      expect(@order.user).to eq @user
      expect(@order.bill_address).to eq bill_address
      expect(@order.ship_address).to eq ship_address
      expect(@order.payments.length).to eq 1
      expect(@order.line_items.any? { |li| li.variant == variant_1 && li.quantity == 2 }).to eq true
      expect(@order.line_items.any? { |li| li.variant == variant_2 && li.quantity == 2 }).to eq true
      expect(@order.promotions).to eq [promotion]
    end

    it "is able to checkout with individualized requests" do
      user_token = login

      create_order(order_headers: user_token)

      create_line_item(variant_1, 2, headers: user_token)
      add_promotion(promotion, headers: user_token)
      create_line_item(variant_2, 2, headers: user_token)

      add_address(bill_address, headers: user_token)
      add_address(ship_address, billing: false, headers: user_token)

      add_payment(headers: user_token)

      advance(headers: user_token)
      complete(headers: user_token)

      assert_order_expectations
    end

    it "is able to checkout with the create request" do
      user_token = login

      create_order(order_headers: user_token, order_params: {
        order: {
          bill_address: bill_address.as_json.except('id'),
          ship_address: ship_address.as_json.except('id'),
          line_items: {
            0 => { variant_id: variant_1.id, quantity: 2 },
            1 => { variant_id: variant_2.id, quantity: 2 }
          },
          # Would like to do this, but the save process from the orders controller
          # does not actually call what it needs to to apply this coupon code :(
          # coupon_code: promotion.code,

          # Would like to do this, but it puts the payment in a complete state,
          # which the order does not like when transitioning from confirm to complete
          # since it looks to process pending payments.
          # payments: [ { payment_method: payment_method.name, state: "pending" } ],
        }
      })

      add_promotion(promotion, headers: user_token)
      add_payment(headers: user_token)

      advance(headers: user_token)
      complete(headers: user_token)

      assert_order_expectations
    end

    it "is able to checkout with the update request" do
      user_token = login

      create_order(order_headers: user_token)
      update_order(order_headers: user_token, order_params: {
        order: {
          bill_address: bill_address.as_json.except('id'),
          ship_address: ship_address.as_json.except('id'),
          line_items: {
            0 => { variant_id: variant_1.id, quantity: 2 },
            1 => { variant_id: variant_2.id, quantity: 2 }
          },
          # Would like to do this, but the save process from the orders controller
          # does not actually call what it needs to to apply this coupon code :(
          # coupon_code: promotion.code,

          # Would like to do this, but it puts the payment in a complete state,
          # which the order does not like when transitioning from confirm to complete
          # since it looks to process pending payments.
          # payments: [ { payment_method: payment_method.name, state: "pending" } ],
        }
      })

      add_promotion(promotion, headers: user_token)
      add_payment(headers: user_token)

      advance(headers: user_token)
      complete(headers: user_token)

      assert_order_expectations
    end
  end
end
