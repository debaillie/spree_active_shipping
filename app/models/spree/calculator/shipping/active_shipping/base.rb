# This is a base calculator for shipping calcualations using the ActiveShipping plugin.  It is not intended to be
# instantiated directly.  Create subclass for each specific shipping method you wish to support instead.
#
# Digest::MD5 is used for cache_key generation.
require 'digest/md5'
require_dependency 'spree/calculator'

module Spree
  module Calculator::Shipping
    module ActiveShipping
      class Base < ShippingCalculator
        include ActiveMerchant::Shipping

        def self.service_name
          self.description
        end

        def available?(package)
          # helps the available? method determine
          # if rates are avaiable for this service
          # before calling the carrier for rates
          is_package_shippable?(package)

          !compute(package).nil?
        rescue Spree::ShippingError
          false
        end

        def compute_package(package)
          order = package.order
          stock_location = package.stock_location

          origin = build_location(stock_location)
          destination = build_location(order.ship_address)

          rates_result = retrieve_rates_from_cache(package, origin, destination)

          return nil if rates_result.kind_of?(Spree::ShippingError)
          return nil if rates_result.empty?
          rate = rates_result[self.class.description]

          return nil unless rate
          rate = rate.to_f + (Spree::ActiveShipping::Config[:handling_fee].to_f || 0.0)

          # divide by 100 since active_shipping rates are expressed as cents
          return rate/100.0
        end

        def timing(line_items)
          order = line_items.first.order
          # TODO: Figure out where stock_location is supposed to come from.
          origin= Location.new(:country => stock_location.country.iso,
                               :city => stock_location.city,
                               :state => (stock_location.state ? stock_location.state.abbr : stock_location.state_name),
                               :zip => stock_location.zipcode)
          addr = order.ship_address
          destination = Location.new(:country => addr.country.iso,
                                     :state => (addr.state ? addr.state.abbr : addr.state_name),
                                     :city => addr.city,
                                     :zip => addr.zipcode)
          timings_result = Rails.cache.fetch(cache_key(package)+"-timings") do
            retrieve_timings(origin, destination, packages(order))
          end
          raise timings_result if timings_result.kind_of?(Spree::ShippingError)
          return nil if timings_result.nil? || !timings_result.is_a?(Hash) || timings_result.empty?
          return timings_result[self.description]

        end

        protected
        # weight limit in ounces or zero (if there is no limit)
        def max_weight_for_country(country)
          0
        end

        private
        # check for known limitations inside a package
        # that will limit you from shipping using a service
        def is_package_shippable? package
          # check for weight limits on service
          country_weight_error? package
        end

        def country_weight_error? package
          max_weight = max_weight_for_country(package.order.ship_address.country)
          raise Spree::ShippingError.new("#{I18n.t(:shipping_error)}: The maximum per package weight for the selected service from the selected country is #{max_weight} ounces.") unless valid_weight_for_package?(package, max_weight)
        end

        # zero weight check means no check
        # nil check means service isn't available for that country
        def valid_weight_for_package? package, max_weight
          return false if max_weight.nil?
          return true if max_weight.zero?
          package.weight <= max_weight
        end

        def retrieve_rates(origin, destination, shipment_packages)
          begin
            response = carrier.find_rates(origin, destination, shipment_packages, :dropoff_type => 'REQUEST_COURIER')
            # turn this beastly array into a nice little hash
            rates = response.rates.collect do |rate|
              service_name = rate.service_name.encode("UTF-8")
              [CGI.unescapeHTML(service_name), rate.price]
            end
            rate_hash = Hash[*rates.flatten]
            return rate_hash
          rescue ActiveMerchant::ActiveMerchantError => e

            if [ActiveMerchant::ResponseError, ActiveMerchant::Shipping::ResponseError].include?(e.class) && e.response.is_a?(ActiveMerchant::Shipping::Response)
              params = e.response.params
              if params.has_key?("Response") && params["Response"].has_key?("Error") && params["Response"]["Error"].has_key?("ErrorDescription")
                message = params["Response"]["Error"]["ErrorDescription"]
              # Canada Post specific error message
              elsif params.has_key?("eparcel") && params["eparcel"].has_key?("error") && params["eparcel"]["error"].has_key?("statusMessage")
                message = e.response.params["eparcel"]["error"]["statusMessage"]
              else
                message = e.message
              end
            else
              message = e.message
            end

            error = Spree::ShippingError.new("#{I18n.t(:shipping_error)}: #{message}")
            Rails.cache.write @cache_key, error #write error to cache to prevent constant re-lookups
            raise error
          end

        end


        def retrieve_timings(origin, destination, packages)
          begin
            if carrier.respond_to?(:find_time_in_transit)
              response = carrier.find_time_in_transit(origin, destination, packages)
              return response
            end
          rescue ActiveMerchant::Shipping::ResponseError => re
            if re.response.is_a?(ActiveMerchant::Shipping::Response)
              params = re.response.params
              if params.has_key?("Response") && params["Response"].has_key?("Error") && params["Response"]["Error"].has_key?("ErrorDescription")
                message = params["Response"]["Error"]["ErrorDescription"]
              else
                message = re.message
              end
            else
              message = re.message
            end

            error = Spree::ShippingError.new("#{I18n.t(:shipping_error)}: #{message}")
            Rails.cache.write @cache_key+"-timings", error #write error to cache to prevent constant re-lookups
            raise error
          end
        end

        def convert_package_to_weights_array(package)
          multiplier = Spree::ActiveShipping::Config[:unit_multiplier]
          default_weight = Spree::ActiveShipping::Config[:default_weight]
          max_weight = get_max_weight(package)

          weights = package.contents.map do |content_item|
            item_weight = content_item.variant.weight.to_f
            item_weight = default_weight if item_weight <= 0
            item_weight *= multiplier

            quantity = content_item.quantity
            if max_weight <= 0
              item_weight * quantity
            elsif item_weight == 0
              0
            else
              if item_weight < max_weight
                max_quantity = (max_weight/item_weight).floor
                if quantity < max_quantity
                  item_weight * quantity
                else
                  new_items = []
                  while quantity > 0 do
                    new_quantity = [max_quantity, quantity].min
                    new_items << (item_weight * new_quantity)
                    quantity -= new_quantity
                  end
                  new_items
                end
              else
                raise Spree::ShippingError.new("#{I18n.t(:shipping_error)}: The maximum per package weight for the selected service from the selected country is #{max_weight} ounces.")
              end
            end
          end
          weights.flatten.compact.sort
        end

        def convert_package_to_item_packages_array(package)
          multiplier = Spree::ActiveShipping::Config[:unit_multiplier]
          max_weight = get_max_weight(package)
          packages = []

          package.contents.each do |content_item|
            variant  = content_item.variant
            quantity = content_item.quantity
            product  = variant.product

            product.product_packages.each do |product_package|
              if product_package.weight.to_f <= max_weight or max_weight == 0
                quantity.times do
                  packages << [product_package.weight * multiplier, product_package.length, product_package.width, product_package.height]
                end
              else
                raise Spree::ShippingError.new("#{I18n.t(:shipping_error)}: The maximum per package weight for the selected service from the selected country is #{max_weight} ounces.")
              end
            end
          end

          packages
        end

        # Generates an array of a single Package object based on the quantities and weights of the variants in the line items
        # NOTE: spree has already split based on it's rules (ie: weight) so we get each split package, so we don't need to split further, just determine total cubic area and weight
        def packages(package)

          weight, volume, count  = 0, 0, 0
          package.contents.each do |pkg|
            pkg.variant.product.product_packages.each do |pp|
              weight += pp.weight
              volume += (pp.length * pp.width * pp.height)
              count += 1
            end
          end
          dimension = volume ** (1/3.0) #cube root
          if count > 1
            dimension *= 1.2 #20% for packing materials on multiple items in a box
            weight *= 1.05 #5% for weight of additional packing materials
          end
          
          #create package for active shipping
          [Package.new(weight * Spree::ActiveShipping::Config[:unit_multiplier],
           [dimension, dimension, dimension], :units => :imperial)]
        end

        def get_max_weight(package)
          order = package.order
          max_weight = max_weight_for_country(order.ship_address.country)
          max_weight_per_package = Spree::ActiveShipping::Config[:max_weight_per_package] * Spree::ActiveShipping::Config[:unit_multiplier]
          if max_weight == 0 and max_weight_per_package > 0
            max_weight = max_weight_per_package
          elsif max_weight > 0 and max_weight_per_package < max_weight and max_weight_per_package > 0
            max_weight = max_weight_per_package
          end

          max_weight
        end

        def cache_key(package)
          stock_location = package.stock_location.nil? ? "" : "#{package.stock_location.id}-"
          order = package.order
          ship_address = package.order.ship_address
          contents_hash = Digest::MD5.hexdigest(package.contents.map {|content_item| content_item.variant.id.to_s + "_" + content_item.quantity.to_s }.join("|"))
          @cache_key = "#{stock_location}#{carrier.name}-#{order.number}-#{ship_address.country.iso}-#{fetch_best_state_from_address(ship_address)}-#{ship_address.city}-#{ship_address.zipcode}-#{contents_hash}-#{I18n.locale}".gsub(" ","")
        end

        def fetch_best_state_from_address address
          address.state ? address.state.abbr : address.state_name
        end

        def build_location address
          Location.new(:country => address.country.iso,
                       :state   => fetch_best_state_from_address(address),
                       :city    => address.city,
                       :zip     => address.zipcode,
                       :address_type => 'commercial')
        end

        def retrieve_rates_from_cache package, origin, destination
          Rails.cache.fetch(cache_key(package)) do
            shipment_packages = packages(package)
            if shipment_packages.empty?
              {}
            else
              retrieve_rates(origin, destination, shipment_packages)
            end
          end
        end
      end
    end
  end
end
