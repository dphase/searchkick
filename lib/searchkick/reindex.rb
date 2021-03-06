module Searchkick
  module Reindex

    # https://gist.github.com/jarosan/3124884
    def reindex
      alias_name = searchkick_index.name
      new_index = alias_name + "_" + Time.now.strftime("%Y%m%d%H%M%S%L")
      index = Tire::Index.new(new_index)

      clean_indices

      success = index.create searchkick_index_options
      raise index.response.to_s if !success

      if a = Tire::Alias.find(alias_name)
        searchkick_import(index) # import before swap

        a.indices.each do |i|
          a.indices.delete i
        end

        a.indices.add new_index
        response = a.save

        if response.success?
          clean_indices
        else
          raise response.to_s
        end
      else
        searchkick_index.delete if searchkick_index.exists?
        response = Tire::Alias.create(name: alias_name, indices: [new_index])
        raise response.to_s if !response.success?

        searchkick_import(index) # import after swap
      end

      index.refresh

      true
    end

    # remove old indices that start w/ index_name
    def clean_indices
      all_indices = JSON.parse(Tire::Configuration.client.get("#{Tire::Configuration.url}/_aliases").body)
      indices = all_indices.select{|k, v| v["aliases"].empty? && k =~ /\A#{Regexp.escape(searchkick_index.name)}_\d{14,17}\z/ }.keys
      indices.each do |index|
        Tire::Index.new(index).delete
      end
      indices
    end

    def self.extended(klass)
      @descendents ||= []
      @descendents << klass unless @descendents.include?(klass)
    end

    private

    def searchkick_import(index)
      batch_size = searchkick_options[:batch_size] || 1000

      # use scope for import
      scope = searchkick_klass
      scope = scope.search_import if scope.respond_to?(:search_import)
      if scope.respond_to?(:find_in_batches)
        scope.find_in_batches batch_size: batch_size do |batch|
          index.import batch.select{|item| item.should_index? }
        end
      else
        # https://github.com/karmi/tire/blob/master/lib/tire/model/import.rb
        # use cursor for Mongoid
        items = []
        scope.all.each do |item|
          items << item if item.should_index?
          if items.length % batch_size == 0
            index.import items
            items = []
          end
        end
        index.import items
      end
    end

    def searchkick_index_options
      options = searchkick_options

      if options[:mappings] and !options[:merge_mappings]
        settings = options[:settings] || {}
        mappings = options[:mappings]
      else
        settings = {
          analysis: {
            analyzer: {
              searchkick_keyword: {
                type: "custom",
                tokenizer: "keyword",
                filter: ["lowercase", "searchkick_stemmer"]
              },
              default_index: {
                type: "custom",
                tokenizer: "standard",
                # synonym should come last, after stemming and shingle
                # shingle must come before searchkick_stemmer
                filter: ["standard", "lowercase", "asciifolding", "searchkick_index_shingle", "searchkick_stemmer"]
              },
              searchkick_search: {
                type: "custom",
                tokenizer: "standard",
                filter: ["standard", "lowercase", "asciifolding", "searchkick_search_shingle", "searchkick_stemmer"]
              },
              searchkick_search2: {
                type: "custom",
                tokenizer: "standard",
                filter: ["standard", "lowercase", "asciifolding", "searchkick_stemmer"]
              },
              # https://github.com/leschenko/elasticsearch_autocomplete/blob/master/lib/elasticsearch_autocomplete/analyzers.rb
              searchkick_autocomplete_index: {
                type: "custom",
                tokenizer: "searchkick_autocomplete_ngram",
                filter: ["lowercase", "asciifolding"]
              },
              searchkick_autocomplete_search: {
                type: "custom",
                tokenizer: "keyword",
                filter: ["lowercase", "asciifolding"]
              },
              searchkick_word_search: {
                type: "custom",
                tokenizer: "standard",
                filter: ["lowercase", "asciifolding"]
              },
              searchkick_suggest_index: {
                type: "custom",
                tokenizer: "standard",
                filter: ["lowercase", "asciifolding", "searchkick_suggest_shingle"]
              },
              searchkick_suggest_index: {
                type: "custom",
                tokenizer: "standard",
                filter: ["lowercase", "asciifolding", "searchkick_suggest_shingle"]
              },
              searchkick_text_start_index: {
                type: "custom",
                tokenizer: "keyword",
                filter: ["lowercase", "asciifolding", "searchkick_edge_ngram"]
              },
              searchkick_text_middle_index: {
                type: "custom",
                tokenizer: "keyword",
                filter: ["lowercase", "asciifolding", "searchkick_ngram"]
              },
              searchkick_text_end_index: {
                type: "custom",
                tokenizer: "keyword",
                filter: ["lowercase", "asciifolding", "reverse", "searchkick_edge_ngram", "reverse"]
              },
              searchkick_word_start_index: {
                type: "custom",
                tokenizer: "standard",
                filter: ["lowercase", "asciifolding", "searchkick_edge_ngram"]
              },
              searchkick_word_middle_index: {
                type: "custom",
                tokenizer: "standard",
                filter: ["lowercase", "asciifolding", "searchkick_ngram"]
              },
              searchkick_word_end_index: {
                type: "custom",
                tokenizer: "standard",
                filter: ["lowercase", "asciifolding", "reverse", "searchkick_edge_ngram", "reverse"]
              }
            },
            filter: {
              searchkick_index_shingle: {
                type: "shingle",
                token_separator: ""
              },
              # lucky find http://web.archiveorange.com/archive/v/AAfXfQ17f57FcRINsof7
              searchkick_search_shingle: {
                type: "shingle",
                token_separator: "",
                output_unigrams: false,
                output_unigrams_if_no_shingles: true
              },
              searchkick_suggest_shingle: {
                type: "shingle",
                max_shingle_size: 5
              },
              searchkick_edge_ngram: {
                type: "edgeNGram",
                min_gram: 1,
                max_gram: 50
              },
              searchkick_ngram: {
                type: "nGram",
                min_gram: 1,
                max_gram: 50
              },
              searchkick_stemmer: {
                type: "snowball",
                language: options[:language] || "English"
              }
            },
            tokenizer: {
              searchkick_autocomplete_ngram: {
                type: "edgeNGram",
                min_gram: 1,
                max_gram: 50
              }
            }
          }
        }

        if searchkick_env == "test"
          settings.merge!(number_of_shards: 1, number_of_replicas: 0)
        end

        settings.deep_merge!(options[:settings] || {})

        # synonyms
        synonyms = options[:synonyms] || []
        if synonyms.any?
          settings[:analysis][:filter][:searchkick_synonym] = {
            type: "synonym",
            synonyms: synonyms.select{|s| s.size > 1 }.map{|s| s.join(",") }
          }
          # choosing a place for the synonym filter when stemming is not easy
          # https://groups.google.com/forum/#!topic/elasticsearch/p7qcQlgHdB8
          # TODO use a snowball stemmer on synonyms when creating the token filter

          # http://elasticsearch-users.115913.n3.nabble.com/synonym-multi-words-search-td4030811.html
          # I find the following approach effective if you are doing multi-word synonyms (synonym phrases):
          # - Only apply the synonym expansion at index time
          # - Don't have the synonym filter applied search
          # - Use directional synonyms where appropriate. You want to make sure that you're not injecting terms that are too general.
          settings[:analysis][:analyzer][:default_index][:filter].insert(4, "searchkick_synonym")
          settings[:analysis][:analyzer][:default_index][:filter] << "searchkick_synonym"
        end

        if options[:special_characters] == false
          settings[:analysis][:analyzer].each do |analyzer, analyzer_settings|
            analyzer_settings[:filter].reject!{|f| f == "asciifolding" }
          end
        end

        mapping = {}

        # conversions
        if options[:conversions]
          mapping[:conversions] = {
            type: "nested",
            properties: {
              query: {type: "string", analyzer: "searchkick_keyword"},
              count: {type: "integer"}
            }
          }
        end

        mapping_options = Hash[
          [:autocomplete, :suggest, :text_start, :text_middle, :text_end, :word_start, :word_middle, :word_end]
            .map{|type| [type, (options[type] || []).map(&:to_s)] }
        ]

        mapping_options.values.flatten.uniq.each do |field|
          field_mapping = {
            type: "multi_field",
            fields: {
              field => {type: "string", index: "not_analyzed"},
              "analyzed" => {type: "string", index: "analyzed"}
              # term_vector: "with_positions_offsets" for fast / correct highlighting
              # http://www.elasticsearch.org/guide/en/elasticsearch/reference/current/search-request-highlighting.html#_fast_vector_highlighter
            }
          }

          mapping_options.each do |type, fields|
            if fields.include?(field)
              field_mapping[:fields][type] = {type: "string", index: "analyzed", analyzer: "searchkick_#{type}_index"}
            end
          end

          mapping[field] = field_mapping
        end

        (options[:locations] || []).each do |field|
          mapping[field] = {
            type: "geo_point"
          }
        end

        mappings = {
          _default_: {
            properties: mapping,
            # https://gist.github.com/kimchy/2898285
            dynamic_templates: [
              {
                string_template: {
                  match: "*",
                  match_mapping_type: "string",
                  mapping: {
                    # http://www.elasticsearch.org/guide/reference/mapping/multi-field-type/
                    type: "multi_field",
                    fields: {
                      # analyzed field must be the default field for include_in_all
                      # http://www.elasticsearch.org/guide/reference/mapping/multi-field-type/
                      # however, we can include the not_analyzed field in _all
                      # and the _all index analyzer will take care of it
                      "{name}" => {type: "string", index: "not_analyzed"},
                      "analyzed" => {type: "string", index: "analyzed"}
                    }
                  }
                }
              }
            ]
          }
        }.deep_merge(options[:mappings] || {})
      end

      {
        settings: settings,
        mappings: mappings
      }
    end

  end
end
