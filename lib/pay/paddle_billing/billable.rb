module Pay
  module PaddleBilling
    class Billable
      attr_reader :pay_customer

      delegate :processor_id,
               :processor_id?,
               :email,
               :customer_name,
               :card_token,
               to: :pay_customer

      def initialize(pay_customer)
        @pay_customer = pay_customer
      end

      def customer_attributes
        { email:, name: customer_name }
      end

      # Retrieves a Paddle::Customer object
      #
      # Finds an existing Paddle::Customer if processor_id exists
      # Creates a new Paddle::Customer using `email` and `customer_name` if empty processor_id
      #
      # Returns a Paddle::Customer object
      def customer
        if processor_id?
          ::Paddle::Customer.retrieve(id: processor_id)
        elsif (pc = ::Paddle::Customer.list(email:).data&.first)
          update!(processor_id: pc.id)
          pc
        else
          pc = ::Paddle::Customer.create(email:, name: customer_name)
          update!(processor_id: sc.id)
          pc
        end
      rescue ::Paddle::Errors::ConflictError => e
        sc = Paddle::Customer.list(email:).data.first
        raise Pay::PaddleBilling::Error, e unless sc.present?

        pay_customer.update!(processor_id: sc.id)
        sc
      end

      # Syncs name and email to Paddle::Customer
      # You can also pass in other attributes that will be merged into the default attributes
      def update_customer!(**attributes)
        customer unless processor_id?
        attrs = customer_attributes.merge(attributes)
        ::Paddle::Customer.update(id: processor_id, **attrs)
      end

      def charge(amount, options = {})
        return Pay::Error unless options

        items = options[:items]
        opts = options.except(:items).merge(customer_id: processor_id)
        transaction = ::Paddle::Transaction.create(items:, **opts)

        attrs = {
          amount: transaction.details.totals.grand_total,
          created_at: transaction.created_at,
          currency: transaction.currency_code,
          metadata: transaction.details.line_items&.first&.id
        }

        charge = pay_customer.charges.find_or_initialize_by(processor_id: transaction.id)
        charge.update(attrs)
        charge
      rescue ::Paddle::Error => e
        raise Pay::PaddleBilling::Error, e
      end

      def subscribe(name: Pay.default_product_name, plan: Pay.default_plan_name, **options)
        # pass
      end

      # Paddle does not use payment method tokens. The method signature has it here
      # to have a uniform API with the other payment processors.
      def add_payment_method(token = nil, default: true)
        Pay::PaddleBilling::PaymentMethod.sync(pay_customer:)
      end

      def trial_end_date(subscription)
        return unless subscription.state == 'trialing'

        Time.zone.parse(subscription.next_payment[:date]).end_of_day
      end

      def processor_subscription(subscription_id, options = {})
        ::Paddle::Subscription.retrieve(id: subscription_id, **options)
      rescue ::Paddle::Error => e
        raise Pay::PaddleBilling::Error, e
      end
    end
  end
end
