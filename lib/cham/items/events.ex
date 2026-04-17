defmodule Cham.Items.Events do
  defmodule ItemCreated do
    @enforce_keys [:item_id, :url]
    defstruct [:item_id, :url]
  end

  defmodule ItemArchived do
    @enforce_keys [:item_id, :slug, :archive_path]
    defstruct [:item_id, :slug, :archive_path]
  end

  defmodule ItemStatusChanged do
    @enforce_keys [:item_id, :status]
    defstruct [:item_id, :status]
  end

  defmodule ItemDeleted do
    @enforce_keys [:item_id]
    defstruct [:item_id, :slug]
  end
end
