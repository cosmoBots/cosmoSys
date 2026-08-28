module Cosmosys
  module ChapterSort
    module_function

    def sql
      table = Issue.table_name
      position = 'COALESCE(cosmosys_chapter_ancestors.csposition, 0)'

      path =
        case ActiveRecord::Base.connection.adapter_name.to_s.downcase
        when /postgres/
          "ARRAY(SELECT #{position} FROM #{table} cosmosys_chapter_ancestors " \
            "WHERE cosmosys_chapter_ancestors.root_id = #{table}.root_id " \
            "AND cosmosys_chapter_ancestors.lft <= #{table}.lft " \
            "AND cosmosys_chapter_ancestors.rgt >= #{table}.rgt " \
            'ORDER BY cosmosys_chapter_ancestors.lft)'
        when /mysql|trilogy/
          "(SELECT GROUP_CONCAT(LPAD(#{position}, 12, '0') " \
            'ORDER BY cosmosys_chapter_ancestors.lft SEPARATOR \'.\') ' \
            "FROM #{table} cosmosys_chapter_ancestors " \
            "WHERE cosmosys_chapter_ancestors.root_id = #{table}.root_id " \
            "AND cosmosys_chapter_ancestors.lft <= #{table}.lft " \
            "AND cosmosys_chapter_ancestors.rgt >= #{table}.rgt)"
        when /sqlite/
          "(SELECT GROUP_CONCAT(cosmosys_chapter_position, '.') FROM (" \
            "SELECT printf('%012d', #{position}) AS cosmosys_chapter_position " \
            "FROM #{table} cosmosys_chapter_ancestors " \
            "WHERE cosmosys_chapter_ancestors.root_id = #{table}.root_id " \
            "AND cosmosys_chapter_ancestors.lft <= #{table}.lft " \
            "AND cosmosys_chapter_ancestors.rgt >= #{table}.rgt " \
            'ORDER BY cosmosys_chapter_ancestors.lft))'
        else
          "#{table}.root_id"
        end

      [path, "#{table}.project_id", "#{table}.root_id", "#{table}.lft", "#{table}.id"]
    end
  end
end
