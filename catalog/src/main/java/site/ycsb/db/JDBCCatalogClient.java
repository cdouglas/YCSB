package site.ycsb.db;


import org.apache.iceberg.CatalogProperties;
import org.apache.iceberg.CatalogUtil;
import org.apache.iceberg.io.FileIOCatalog;
import org.apache.iceberg.jdbc.JdbcCatalog;
import site.ycsb.DBException;

import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

public class JDBCCatalogClient extends CatalogClient<FileIOCatalog> {

  @Override
  public void init() throws DBException {
    HashMap<String, String> properties = new HashMap<>();
    properties.put(
        CatalogProperties.URI,
        "jdbc:sqlite:file::memory:?ic" + UUID.randomUUID().toString().replace("-", ""));
    properties.put(CatalogProperties.CATALOG_IMPL, JdbcCatalog.class.getName());
    properties.put(JdbcCatalog.PROPERTY_PREFIX + "user", "admin");
    properties.put(JdbcCatalog.PROPERTY_PREFIX + "password", "pass");
    properties.put(CatalogProperties.WAREHOUSE_LOCATION, warehouse);
    try{
      catalog = (JdbcCatalog) CatalogUtil.buildIcebergCatalog("test_jdbc_catalog", properties, null);
    } catch (Exception e){
      throw new DBException("An error occurred while building the JDBC Catalog. Ensure you have jdbc::sqlite drivers.");
    }
  }
}
