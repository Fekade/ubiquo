require "i18n"

module RoutingFilter
  class UbiquoLocale < Filter
    include Ubiquo::Extensions::ConfigCaller

    attr_writer :include_default_locale

    def initialize(options = {})
      default = options.delete(:include_default_locale)
      @include_default_locale = default.nil? ? true : default

      super
    end

    def around_recognize(path, env)
      locale = extract_segment!(locales_pattern, path)
      yield.tap do |params|
        params[:locale] ||= locale if locale
      end
    end

    def around_generate(*args)
      params = args.extract_options!
      locale = extract_locale_from_params(params)

      yield.tap do |result|
        localize_ubiquo_route(locale, result)
      end
    end

    protected

    def localize_ubiquo_route(locale, result)
      if prepend_locale?(locale)
        url = extract_url!(result)
        prepend_segment!(url, "#{locale}")
      end

      result
    end

    def extract_locale_from_params(params)
      locale = params[:locale]
      locale = nil unless valid_locale?(locale)
      locale ||= default_locale

      params.delete(:locale) if clean_url_params?

      locale
    end

    def include_default_locale?
      @include_default_locale
    end

    def locales
      @locales ||= ::Locale.active.map(&:to_s).map(&:to_sym)
    end

    def locales=(locales)
      @locales = locales.map(&:to_s).map(&:to_sym)
    end

    def locales_pattern
      @locales_pattern ||= begin
        _locales = locales.map { |l| Regexp.escape(l.to_s) }.join('|')
        %r(/(#{_locales})(?=/|$))
      end
    end

    def valid_locale?(locale)
      locale.present? && locales.include?(locale.to_s.to_sym)
    end

    def default_locale?(locale)
      locale && locale.to_sym == default_locale
    end

    def default_locale
      ::Locale.current.to_s.to_sym
    end

    def prepend_locale?(locale)
      locale && (include_default_locale? || !default_locale?(locale))
    end

    def extract_url!(path)
      path.is_a?(Array) ? path.first : path
    end

    def extract_url(path)
      extract_url!(path).dup
    end

    def clean_url_params?
      ubiquo_config_call(:clean_url_params, { :context => :ubiquo_i18n })
    end
  end
end
