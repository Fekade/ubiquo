module UbiquoI18n
  module Extensions
    module ActiveRecord

      def self.append_features(base)
        super
        base.extend(ClassMethods)
        base.send :include, InstanceMethods
      end

      module ClassMethods
        
        # Class method for ActiveRecord that states which attributes are translatable and therefore when updated will be only updated for the current locale.
        #
        # EXAMPLE:
        #
        #   translatable :title, :description
        # 
        # possible options:
        #   :timestamps => set to false to avoid translatable (i.e. independent per translation) timestamps

        def translatable(*attrs)
          @translatable = true
          # inherit translatable attributes
          @translatable_attributes = self.superclass.instance_variable_get('@translatable_attributes') || []
          # extract and parse options
          options = attrs.extract_options!
          # add attrs from this class
          @translatable_attributes += attrs
          
          # timestamps are independent per translation unless set
          @translatable_attributes += [:created_at, :updated_at] unless options[:timestamps] == false
          
          # try to generate the attribute setter
          self.new.send(:locale=, :generate) rescue nil
          if instance_methods.include?('locale=') && !instance_methods.include?('locale_with_duality=')
            # give the proper behaviour to the locale setter
            define_method('locale_with_duality=') do |locale|
              locale = case locale
              when String
                locale
              else
                locale.iso_code if locale.respond_to?(:iso_code)
              end
              send(:locale_without_duality=, locale)
            end

            alias_method_chain :locale=, :duality

          end
          
          unless instance_methods.include?("in_locale")
            define_method('in_locale') do |*locales|
              self.class.locale(*locales).first(:conditions => {:content_id => self.content_id})
            end
          end
          
          # usage:
          # find all content in any locale: Model.locale(:ALL)
          # find spanish content: Model.locale('es')
          # find spanish or english content. If spanish and english exists, gets the spanish version. Model.locale('es', 'en')
          # find all content in spanish or any other locale if spanish dosn't exist: Model.locale('es', :ALL)
          # find all content in any locale: Model.locale(:ALL)
          #
          named_scope :locale, lambda{|*locales|
            @locale_namespaced = true
            @current_locale_list ||= []
            @current_locale_list += locales
            {}
          }
                    
          # usage:
          # find all items of one content: Model.content(1).first
          # find all items of some contents: Model.content(1,2,3)
          named_scope :content, lambda{|*content_ids|
            {:conditions => {:content_id => content_ids}}
          }

          # usage:
          # find all translations of a given content: Model.translations(content)
          # will use the defined scopes to discriminate what are translations
          # remember it won't return 'content' itself
          named_scope :translations, lambda{|content|
            scoped_conditions = []
            @translatable_scopes.each do |scope|
                scoped_conditions << (String === scope ? scope : scope.call(content))
            end
             translation_condition = "#{self.table_name}.content_id = ? AND #{self.table_name}.locale != ?"
            unless scoped_conditions.blank?
              translation_condition += ' AND ' + scoped_conditions.join(' AND ')
            end
            {:conditions => [translation_condition, content.content_id, content.locale]}
          }
          
          # Instance method to find translations
          define_method('translations') do
            self.class.translations(self)
          end
          
          # Creates a new instance of the translatable class, using the common
          # values from an instance sharing the same content_id
          # Returns a new independent instance if content_id is nil or not found
          def translate(content_id, locale)
            original = find_by_content_id(content_id)
            new_translation = original ? original.translate(locale) : new
            new_translation.locale = locale
            new_translation
          end

          # Creates (saving) a new translation of self, with the common values filled in
          define_method('translate') do |locale|
            self.while_being_translated lambda{
              new_translation = self.class.new
              new_translation.locale = locale
              self.untranslatable_attributes.each_pair do |attr, value|
                new_translation.send("#{attr}=", value)
              end
              new_translation.copy_translatable_shared_relations_from self
              new_translation
            }
          end
          
          define_method('while_being_translated') do |closure|
            # find or create the current translations list and add myself to it
            current_translations = ::ActiveRecord::Base.instance_variable_get('@current_translations')
            if !current_translations 
              current_translations = [self]
              ::ActiveRecord::Base.instance_variable_set('@current_translations', current_translations)
            else 
              current_translations << self
            end            
            
            # execute the code and, no matter what happens, when this is finished remove myself from
            # the current translations list
            begin
              # TODO replace with a block when migrating to Ruby 1.9
              result = closure.call
            rescue
              raise
              current_translations = ::ActiveRecord::Base.instance_variable_get('@current_translations')
              current_translations.delete(self)
            end
            current_translations = ::ActiveRecord::Base.instance_variable_get('@current_translations')
            current_translations.delete(self)
            result
          end
          
          define_method('being_translated?') do
            (ct = (::ActiveRecord::Base.instance_variable_get('@current_translations') || [])) && ct.include?(self)
          end
          
          define_method('translation_on_process') do |on_process|
            unless on_process == false
              # find or create the current on process translations list and add myself to it
              current_translations = ::ActiveRecord::Base.instance_variable_get('@current_translations_on_process')
              if !current_translations 
                current_translations = [self]
                ::ActiveRecord::Base.instance_variable_set('@current_translations_on_process', current_translations)
              else 
                current_translations << self
              end
            else
              current_translations = ::ActiveRecord::Base.instance_variable_get('@current_translations_on_process')
              current_translations.delete(self)
            end
          end
          
          # Looks for defined shared relations and performs a chain-update on them
          define_method('copy_translatable_shared_relations_from') do |model|
            self.class.instance_variable_set('@is_translating_relations', true)
            self.translation_on_process true
            begin
              # act on reflections where translatable == false
              self.class.reflections.select{|name, ref| ref.options[:translatable] == false}.each do |rel, values|
                  model_rel = model.send(rel)
                  record = [model_rel].flatten.first
                  if record && record.class.is_translatable?
                    all_relationship_contents = []
                    [model_rel].flatten.each do |old_rel|
                      existing_translation = old_rel.translations.first(:conditions => {:locale => self.locale})
                      unless existing_translation || old_rel.being_translated?
                        translated_rel = old_rel.translate(self.locale)
                        all_relationship_contents << translated_rel
                        translated_rel.save
                      else 
                        if old_rel.being_translated?
                        # maybe it doesn't exist in db but it does in memory 
                        # it means that is currently being translated and there is something self-referential
                          ::ActiveRecord::Base.instance_variable_get('@current_translations_on_process').each do |ct|
                            if ct.class == old_rel.class && ct.locale == self.locale && ct.content_id == old_rel.content_id
                              all_relationship_contents << ct
                            end
                          end
                        end
                      end
                    end
                  elsif record
                    #unless "This model doesn't lead to a :through"
                      raise "This behaviour is not supported by ubiquo_i18n. Either use a has_many :through to a translatable model or mark the #{record.class} model as translatable"
                    #end
                    # This is the code if we want to enable duplicates
#                    all_relationship_contents = []
#                    [model_rel].flatten.each do |old_rel|
#                      translated_rel = old_rel.clone
#                      all_relationship_contents << translated_rel
#                      translated_rel.save
#                    end
                  else 
                    next
                  end
                  all_relationship_contents = all_relationship_contents.first unless model_rel.is_a?(Array)
                  self.send(rel.to_s + '=', all_relationship_contents)
              end
            rescue
              self.class.instance_variable_set('@is_translating_relations', false)
              self.translation_on_process(false)
              raise
            end
            self.class.instance_variable_set('@is_translating_relations', false)
            self.translation_on_process(false)
          end
          
        end
        
        # Returns true if the class is marked as translatable
        def is_translatable?
          @translatable || @translatable.nil? && self.superclass.respond_to?(:is_translatable?) && self.superclass.is_translatable?
        end        
        
        # Adds :current_version => true to versionable models unless explicitly said :version option
        def find_with_locale_filter(*args)
          if self.is_translatable?
            options = args.extract_options!
            apply_locale_filter!(options)
            find_without_locale_filter(args.first, options)
          else
            find_without_locale_filter(*args)
          end
        end
        
        def count_with_locale_filter(*args)
          if self.is_translatable?
            options = args.extract_options!
            apply_locale_filter!(options)
            count_without_locale_filter(args.first, options)
          else
            count_without_locale_filter(*args)
          end
        end
        
        def apply_locale_filter!(options)        
          apply_locale_filter = @locale_namespaced
          locales = @current_locale_list
          # set this find as dispatched
          @locale_namespaced = false
          @current_locale_list = []
          if apply_locale_filter
            # build locale restrictions
            locales.uniq!
            all_locales = locales.delete(:ALL)
            
            locale_conditions = all_locales ? "" : ["#{self.table_name}.locale in (?)", locales]

            # expand our sql to match the potential conditions
            join_dependency = ::ActiveRecord::Associations::ClassMethods::JoinDependency.new(self, merge_includes(scope(:find, :include), options[:include]), options[:joins])
            joins_sql = join_dependency.join_associations.collect{|join| join.association_join }.join
            conditions_sql = add_conditions!('', merge_conditions(locale_conditions, options[:conditions]), scope(:find))

            # locale preference order 
            locales_string = locales.size > 0 ? (["#{self.table_name}.locale != ?"]*(locales.size)).join(", ") : nil

            # build the subquery and add it as a condition to the original options
            locale_filter = ["#{self.table_name}.id in (" +
                "SELECT distinct on (#{self.table_name}.content_id) #{self.table_name}.id " + 
                "FROM #{self.table_name} " + joins_sql.to_s + conditions_sql.to_s +
                "ORDER BY #{ ["#{self.table_name}.content_id", locales_string].compact.join(", ")})", *locales]
            options[:conditions] = merge_conditions(options[:conditions], locale_filter)
          end
        end

        
        # Attributes that are always 'translated' (not copied between languages)
        (@global_translatable_attributes ||= []) << :locale << :content_id

        # Used by third parties to add fields that should always 
        # be independent between different languages 
        def add_translatable_attributes(*args)
          @global_translatable_attributes += args
        end
        
        # Define scopes to limit the automatic update of common fields to instances
        # that have the same value for each scope (as a field name)
        @translatable_scopes ||= [] 

        # Used by third parties to add scopes for translations updates of common fields
        # It accepts two formats for condition:
        # - A String with a sql where condition (e.g. is_active = 1)
        # - A Proc that will be called with the current element argument and
        #   that should return a string (e.g. lambda{|el| "table.field = #{el.field + 1}"})
        def add_translatable_scope(condition)
          @translatable_scopes << condition
        end
        
        @@translatable_inheritable_instance_variables = %w{global_translatable_attributes translatable_scopes}

        ASSOCIATION_TYPES = %w{ has_one belongs_to has_many has_and_belongs_to_many }

        def self.extended(klass)
          @@translatable_inheritable_instance_variables.each do |inheritable|
            klass.instance_variable_set("@#{inheritable}", eval("@#{inheritable}").dup)
          end
          klass.class_eval do
            class << self
              alias_method_chain :find, :locale_filter
              alias_method_chain :count, :locale_filter
            end
          end
          
          # Accept the :translatable option when defining associations
          ASSOCIATION_TYPES.each do |type|
            klass.send("valid_keys_for_#{type}_association") << :translatable
          end
        end
        
        def inherited(klass)
          super
          @@translatable_inheritable_instance_variables.each do |inheritable|
            klass.instance_variable_set("@#{inheritable}", eval("@#{inheritable}").dup)
          end
        end

      end
      
      module InstanceMethods
        
        def self.included(klass)
          klass.alias_method_chain :update, :translatable
          klass.alias_method_chain :create, :translatable
          klass.alias_method_chain :create, :i18n_content_id
          
        end
        
        # proxy to add a new content_id if empty on creation
        def create_with_i18n_content_id
          if self.class.is_translatable?
            # we do this even if there is not currently any tr. attribute, 
            # as long as is a translatable model
            unless self.content_id
              self.content_id = self.class.connection.next_val_sequence("#{self.class.table_name}_content_id")
            end
          end
          create_without_i18n_content_id
        end
        
        # Whenever we update existing content or create a translation, the expected behaviour is the following
        # - The translatable fields will be updated just for the current instance
        # - Fields not defined as translatable will need to be updated for every instance that shares the same content_id
        def create_with_translatable
          create_without_translatable
          update_translations
        end

        def update_with_translatable
          update_without_translatable
          update_translations
        end

        def update_translations
          if self.class.is_translatable? && !@stop_translatable_propagation
            # Update the translations
            self.translations.each do |translation|
              translation.instance_variable_set('@stop_translatable_propagation', true)
              begin 
                translation.update_attributes untranslatable_attributes
              rescue
                translation.instance_variable_set('@stop_translatable_propagation', false)
                raise
              end
              translation.instance_variable_set('@stop_translatable_propagation', false)
            end
          end
        end
        
        def untranslatable_attributes_names
          translatable_attributes = (self.class.instance_variable_get('@translatable_attributes') || []) + 
            (self.class.instance_variable_get('@global_translatable_attributes') || []) +
            (self.class.reflections.select{|name, ref| ref.options[:translatable] != false}.map{|name, ref| ref.primary_key_name})
          attribute_names - translatable_attributes.map{|attr| attr.to_s}
        end
        
        def untranslatable_attributes
          attrs = {}
          (untranslatable_attributes_names + [:content_id.to_s] - [:id.to_s]).each do |name|
            attrs[name] = clone_attribute_value(:read_attribute, name)
          end
          attrs
        end

      end

    end
  end
end
