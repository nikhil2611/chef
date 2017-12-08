#
# Author:: Lamont Granquist (<lamont@chef.io>)
# Copyright:: Copyright 2014-2017, Chef Software Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

#
# example of a NodeMap entry for the user resource (as typed on the DSL):
#
#  :user=>
#  [{:klass=>Chef::Resource::User::AixUser, :os=>"aix"},
#   {:klass=>Chef::Resource::User::DsclUser, :os=>"darwin"},
#   {:klass=>Chef::Resource::User::PwUser, :os=>"freebsd"},
#   {:klass=>Chef::Resource::User::LinuxUser, :os=>"linux"},
#   {:klass=>Chef::Resource::User::SolarisUser,
#    :os=>["omnios", "solaris2"]},
#   {:klass=>Chef::Resource::User::WindowsUser, :os=>"windows"}],
#
# the entries in the array are pre-sorted into priority order (blocks/platform_version/platform/platform_family/os/none) so that
# the first entry's :klass that matches the filter is returned when doing a get.
#
# note that as this examples show filter values may be a scalar string or an array of scalar strings.
#
# XXX: confusingly, in the *_priority_map the :klass may be an array of Strings of class names
#
class Chef
  class NodeMap

    #
    # Set a key/value pair on the map with a filter.  The filter must be true
    # when applied to the node in order to retrieve the value.
    #
    # @param key [Object] Key to store
    # @param value [Object] Value associated with the key
    # @param filters [Hash] Node filter options to apply to key retrieval
    #
    # @yield [node] Arbitrary node filter as a block which takes a node argument
    #
    # @return [NodeMap] Returns self for possible chaining
    #
    def set(key, klass, platform: nil, platform_version: nil, platform_family: nil, os: nil, canonical: nil, override: nil, &block)
      new_matcher = { klass: klass }
      new_matcher[:platform] = platform if platform
      new_matcher[:platform_version] = platform_version if platform_version
      new_matcher[:platform_family] = platform_family if platform_family
      new_matcher[:os] = os if os
      new_matcher[:block] = block if block
      new_matcher[:canonical] = canonical if canonical
      new_matcher[:override] = override if override

      # The map is sorted in order of preference already; we just need to find
      # our place in it (just before the first value with the same preference level).
      insert_at = nil
      map[key] ||= []
      map[key].each_with_index do |matcher, index|
        cmp = compare_matchers(key, new_matcher, matcher)
        if cmp && cmp <= 0
          insert_at = index
          break
        end
      end
      if insert_at
        map[key].insert(insert_at, new_matcher)
      else
        map[key] << new_matcher
      end
      map
    end

    #
    # Get a value from the NodeMap via applying the node to the filters that
    # were set on the key.
    #
    # @param node [Chef::Node] The Chef::Node object for the run, or `nil` to
    #   ignore all filters.
    # @param key [Object] Key to look up
    # @param canonical [Boolean] `true` or `false` to match canonical or
    #   non-canonical values only. `nil` to ignore canonicality.  Default: `nil`
    #
    # @return [Object] Class
    #
    def get(node, key, canonical: nil)
      return nil unless map.has_key?(key)
      map[key].map do |matcher|
        return matcher[:klass] if node_matches?(node, matcher) && canonical_matches?(canonical, matcher)
      end
      nil
    end

    #
    # List all matches for the given node and key from the NodeMap, from
    # most-recently added to oldest.
    #
    # @param node [Chef::Node] The Chef::Node object for the run, or `nil` to
    #   ignore all filters.
    # @param key [Object] Key to look up
    # @param canonical [Boolean] `true` or `false` to match canonical or
    #   non-canonical values only. `nil` to ignore canonicality.  Default: `nil`
    #
    # @return [Object] Class
    #
    def list(node, key, canonical: nil)
      return [] unless map.has_key?(key)
      map[key].select do |matcher|
        node_matches?(node, matcher) && canonical_matches?(canonical, matcher)
      end.map { |matcher| matcher[:klass] }
    end

    # Seriously, don't use this, it's nearly certain to change on you
    # @return remaining
    # @api private
    def delete_canonical(key, klass)
      remaining = map[key]
      if remaining
        remaining.delete_if { |matcher| matcher[:canonical] && Array(matcher[:klass]) == Array(klass) }
        if remaining.empty?
          map.delete(key)
          remaining = nil
        end
      end
      remaining
    end

    private

    #
    # Succeeds if:
    # - no negative matches (!value)
    # - at least one positive match (value or :all), or no positive filters
    #
    def matches_black_white_list?(node, filters, attribute)
      # It's super common for the filter to be nil.  Catch that so we don't
      # spend any time here.
      return true if !filters[attribute]
      filter_values = Array(filters[attribute])
      value = node[attribute]

      # Split the blacklist and whitelist
      blacklist, whitelist = filter_values.partition { |v| v.is_a?(String) && v.start_with?("!") }

      # If any blacklist value matches, we don't match
      return false if blacklist.any? { |v| v[1..-1] == value }

      # If the whitelist is empty, or anything matches, we match.
      whitelist.empty? || whitelist.any? { |v| v == :all || v == value }
    end

    def matches_version_list?(node, filters, attribute)
      # It's super common for the filter to be nil.  Catch that so we don't
      # spend any time here.
      return true if !filters[attribute]
      filter_values = Array(filters[attribute])
      value = node[attribute]

      filter_values.empty? ||
        Array(filter_values).any? do |v|
          Gem::Requirement.new(v).satisfied_by?(Gem::Version.new(value))
        end
    end

    def filters_match?(node, filters)
      matches_black_white_list?(node, filters, :os) &&
        matches_black_white_list?(node, filters, :platform_family) &&
        matches_black_white_list?(node, filters, :platform) &&
        matches_version_list?(node, filters, :platform_version)
    end

    def block_matches?(node, block)
      return true if block.nil?
      block.call node
    end

    def node_matches?(node, matcher)
      return true if !node
      filters_match?(node, matcher) && block_matches?(node, matcher[:block])
    end

    def canonical_matches?(canonical, matcher)
      return true if canonical.nil?
      !!canonical == !!matcher[:canonical]
    end

    # @api private
    def dispatch_compare_matchers(key, new_matcher, matcher)
      cmp = compare_matcher_properties(new_matcher[:block], matcher[:block])
      return cmp if cmp != 0
      cmp = compare_matcher_properties(new_matcher[:platform_version], matcher[:platform_version])
      return cmp if cmp != 0
      cmp = compare_matcher_properties(new_matcher[:platform], matcher[:platform])
      return cmp if cmp != 0
      cmp = compare_matcher_properties(new_matcher[:platform_family], matcher[:platform_family])
      return cmp if cmp != 0
      cmp = compare_matcher_properties(new_matcher[:os], matcher[:os])
      return cmp if cmp != 0
      cmp = compare_matcher_properties(new_matcher[:override], matcher[:override])
      return cmp if cmp != 0
      # If all things are identical, return 0
      0
    end

    #
    # "provides" lines with identical filters sort by class name (ascending).
    #
    def compare_matchers(key, new_matcher, matcher)
      cmp = dispatch_compare_matchers(key, new_matcher, matcher)
      if cmp == 0
        # Sort by class name (ascending) as well, if all other properties
        # are exactly equal
        # XXX: remove this in Chef-14 and use last-writer-wins (prepend if they match)
        if !new_matcher[:override]
          # we only sort classes, which only sorts the handler array, this magically does not sort
          # the priority array via the invisible else here.
          if new_matcher[:klass].is_a?(Class)
            cmp = compare_matcher_properties(new_matcher[:klass].name, matcher[:klass].name)
          end
        end
      end
      cmp
    end

    def compare_matcher_properties(a, b)
      # falsity comparisons here handle both "nil" and "false"
      return 1 if !a && b
      return -1 if !b && a
      return 0 if !a && !b

      # Check for blacklists ('!windows'). Those always come *after* positive
      # whitelists.
      a_negated = Array(a).any? { |f| f.is_a?(String) && f.start_with?("!") }
      b_negated = Array(b).any? { |f| f.is_a?(String) && f.start_with?("!") }
      return 1 if a_negated && !b_negated
      return -1 if b_negated && !a_negated

      a <=> b
    end

    def map
      @map ||= {}
    end
  end
end
