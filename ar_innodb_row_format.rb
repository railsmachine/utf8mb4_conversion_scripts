ActiveSupport.on_load :active_record do
  module AbstractMysqlAdapterWithInnodbRowFormatDynamic
    def create_table(table_name, options = {})
      super(table_name,
            options.reverse_merge(
              :options => 'ENGINE=InnoDB ROW_FORMAT=DYNAMIC'))
    end
  end

  ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter
    .send(:prepend, AbstractMysqlAdapterWithInnodbRowFormatDynamic)
end
